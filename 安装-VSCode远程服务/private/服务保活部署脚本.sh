#!/bin/sh
# VS Code 服务保活部署脚本（Linux 远程主机专用）
# 兼容 POSIX sh（bash/dash/ash），此文件通过主模块上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。
# 注意：bash 变量名不支持非 ASCII 字符，故变量使用英文，注释与输出保持中文。
#
# 目标：把 Remote-SSH exec server 的启动入口 CLI（<数据目录>/code[-insiders]-<提交号>）替换为包装脚本，使真正的command-shell进程以「双 fork + setsid」拉起（PPID 归 1、自建会话与进程组），从而在登录节点周期性收割超龄会话时存活，让本地 VS Code 断线重连时直接热附着（复用 pid.txt 与 connectionToken）而非冷启动。
#
# 关键约束（实测教训）：官方 linux-exec-server-installer.sh 每次连接都会做 GC——
#   ls -1t <数据目录> | grep -E 'code(-insiders)?-[0-9a-fA-F]{40}' | tail -n +6 | xargs rm -rf
# 该匹配无锚点，凡数据目录内符合命名的文件都可能被当作旧版删除，且只保留最新 5 个。故：
#   1) 真实 CLI 二进制备份必须放在数据目录之外（PERSIST_DIR/real），否则会被 GC 连带删除；
#   2) 数据目录内的包装脚本数量必须恒少于 6（KEEP=2），GC 便永不触发。

set -eu

# ===== 由主模块替换的参数 =====
ACTION='__动作__'
DATA_DIR='__数据目录__'
PERSIST_DIR='__服务保活目录__'
CURRENT_CLI='__CLI文件名__'
CURRENT_COMMIT='__当前提交号__'
CHANNEL='__发布通道__'
WRAP_TEMPLATE='__包装脚本路径__'

REAL_DIR="$PERSIST_DIR/real"
WRAP_LOG="$PERSIST_DIR/wrapper.log"
KEEP=2
MARK='vscode-persistent-wrapper-v2'
# 包装脚本内容版本标记：与包装脚本模板（服务保活包装脚本.sh）头部「包装脚本版本:」那一行对应。
# 步骤 3 靠它区分“已是当前版本”与“旧版包装脚本”；凡改变脱逃方式或 wrapper 行为，必须同步递增本标记与模板头部那一行，否则已部署的旧 wrapper 永远不会被升级。MARK 只标识身份、不随内容版本变动：移除路径靠它认出已部署的 wrapper 并把真身放回原位，改 MARK 会导致旧 wrapper 无法还原。
WRAP_VERSION='WRAPPER-V4-DOUBLE-FORK'
URL_BASE='https://update.code.visualstudio.com'

log() {
	echo "[保活] $*"
}

# 依据架构推导 CLI 下载 artifact 名（与官方引导脚本规则一致：armhf 用 cli-linux-armhf，其余用 cli-alpine-<arch>）
detect_cli_artifact() {
	MACHINE=$(uname -m)
	case "$MACHINE" in
		x86_64 | amd64)
			echo 'cli-alpine-x64'
			;;
		aarch64 | arm64)
			echo 'cli-alpine-arm64'
			;;
		armv7l | armv6l | armhf | arm)
			echo 'cli-linux-armhf'
			;;
		*)
			echo ''
			;;
	esac
}

# 下载真实 CLI 到指定路径（$1 提交号 $2 发布通道 $3 目标文件），成功后用 --version 校验
download_real() {
	DL_COMMIT="$1"
	DL_QUALITY="$2"
	DL_DEST="$3"
	DL_DIR=$(dirname "$DL_DEST")
	ARTIFACT=$(detect_cli_artifact)
	if [ -z "$ARTIFACT" ]; then
		log "无法识别远程架构（uname -m），跳过下载"
		return 1
	fi
	if [ "$DL_QUALITY" = 'insider' ]; then
		IN_ARCHIVE='code-insiders'
	else
		IN_ARCHIVE='code'
	fi
	DL_URL="$URL_BASE/commit:$DL_COMMIT/$ARTIFACT/$DL_QUALITY"
	DL_TMP="$DL_DEST.$$"
	mkdir -p "$DL_DIR"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 600 -o "$DL_TMP" "$DL_URL" || { rm -f "$DL_TMP"; return 1; }
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$DL_TMP" "$DL_URL" || { rm -f "$DL_TMP"; return 1; }
	else
		rm -f "$DL_TMP"
		log '远程主机缺少 curl 与 wget，无法下载真实 CLI'
		return 1
	fi

	tar -xf "$DL_TMP" --no-same-owner -C "$DL_DIR" >/dev/null 2>&1
	TAR_RC=$?
	rm -f "$DL_TMP"
	if [ "$TAR_RC" -ne 0 ] || [ ! -f "$DL_DIR/$IN_ARCHIVE" ]; then
		log "解包失败或包内缺少 $IN_ARCHIVE"
		return 1
	fi
	mv -f "$DL_DIR/$IN_ARCHIVE" "$DL_DEST"
	chmod 755 "$DL_DEST"
	"$DL_DEST" --version >/dev/null 2>&1
}

# 生成包装脚本到 $1：包装脚本正文独立存放在模板文件 WRAP_TEMPLATE（由主模块上传），此处仅把 @@PERSIST_DIR@@ 替换为真实路径后落位
write_wrapper() {
	if [ ! -f "$WRAP_TEMPLATE" ]; then
		echo "[保活] 错误: 包装脚本模板不存在: $WRAP_TEMPLATE" >&2
		exit 1
	fi
	sed "s|@@PERSIST_DIR@@|$PERSIST_DIR|g" "$WRAP_TEMPLATE" > "$1.$$"
	mv -f "$1.$$" "$1"
	chmod 755 "$1"
}

# ===== 移除模式：还原官方原始布局 =====
if [ "$ACTION" = '移除' ]; then
	RESTORED=0
	for F in "$DATA_DIR"/code-*; do
		[ -f "$F" ] || continue
		BASE=$(basename "$F")
		case "$BASE" in
			*.real | *.tmp) continue ;;
		esac
		if head -c 400 "$F" 2>/dev/null | grep -qi "$MARK"; then
			if [ -f "$REAL_DIR/$BASE" ]; then
				mv -f "$REAL_DIR/$BASE" "$F"
			else
				rm -f "$F"
			fi
			RESTORED=$((RESTORED + 1))
			log "已还原 $BASE"
		fi
	done
	rm -f "$REAL_DIR"/code-* "$WRAP_LOG"
	rmdir "$REAL_DIR" "$PERSIST_DIR" 2>/dev/null || true
	log "移除完成，共还原 $RESTORED 个包装脚本，数据目录恢复为官方布局。"
	exit 0
fi

# ===== 部署模式 =====
if ! command -v setsid >/dev/null 2>&1; then
	echo '[保活] 错误: 远程主机没有 setsid 命令，无法脱离 sshd 会话。' >&2
	exit 1
fi
mkdir -p "$REAL_DIR"

# 1) 数据目录内的裸 ELF：移入真身目录，并在原处写入包装脚本（保留官方引导脚本按文件名找到入口的契约）
for F in "$DATA_DIR"/code-*; do
	[ -f "$F" ] || continue
	BASE=$(basename "$F")
	case "$BASE" in
		*.real | *.tmp) continue ;;
	esac
	MAGIC=$(head -c 4 "$F" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	if [ "$MAGIC" = '7f454c46' ]; then
		mv -f "$F" "$REAL_DIR/$BASE"
		write_wrapper "$F"
		log "裸 ELF 迁移并包装: $BASE"
	fi
done

# 2) 兼容更早版本的同目录 .real 备份：一并迁入真身目录，避免留在数据目录被官方 GC 误删
for R in "$DATA_DIR"/*.real; do
	[ -f "$R" ] || continue
	BASE=$(basename "$R" .real)
	if [ ! -f "$REAL_DIR/$BASE" ]; then
		mv -f "$R" "$REAL_DIR/$BASE"
		log "迁移旧备份: $BASE"
	else
		rm -f "$R"
		log "清理重复旧备份: $(basename "$R")"
	fi
done

# 3) 其余非 ELF 的 code-*（旧版包装脚本或损坏文件）重写为当前版本；已是当前版本则跳过，以保持 mtime 稳定
for F in "$DATA_DIR"/code-*; do
	[ -f "$F" ] || continue
	BASE=$(basename "$F")
	case "$BASE" in
		*.real | *.tmp) continue ;;
	esac
	MAGIC=$(head -c 4 "$F" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	[ "$MAGIC" = '7f454c46' ] && continue
	# 版本标记命中才跳过；否则视为旧版包装脚本（例如只靠 setsid 的 v2），重写为当前版本
	if grep -q "$WRAP_VERSION" "$F" 2>/dev/null && head -c 600 "$F" 2>/dev/null | grep -qi "$MARK"; then
		continue
	fi
	write_wrapper "$F"
	log "包装脚本升级重写: $BASE"
done

# 4) 当前提交号的入口若完全不存在，则先下载真身再包装（首次部署或远程被清理后的自愈）
if [ ! -f "$DATA_DIR/$CURRENT_CLI" ]; then
	log "数据目录缺少 $CURRENT_CLI，先下载真实 CLI"
	if download_real "$CURRENT_COMMIT" "$CHANNEL" "$REAL_DIR/$CURRENT_CLI"; then
		mkdir -p "$DATA_DIR"
		write_wrapper "$DATA_DIR/$CURRENT_CLI"
		log '下载并包装完成'
	else
		log '下载失败，放弃本次部署'
		exit 1
	fi
fi

# 5) 保留策略：把当前提交号钉在首位，加上按 mtime 最新的共 KEEP 个，其余包装脚本与真身一并剪枝
PINNED="$DATA_DIR/$CURRENT_CLI"
CANDIDATES=$(ls -1t "$DATA_DIR"/code-* 2>/dev/null | grep -v -E '\.(real|tmp)$' || true)
if [ -f "$PINNED" ]; then
	CANDIDATES=$(printf '%s\n%s\n' "$PINNED" "$(printf '%s\n' "$CANDIDATES" | grep -vx "$PINNED" || true)")
	log "钉住保护: $CURRENT_CLI"
fi

INDEX=0
for W in $CANDIDATES; do
	INDEX=$((INDEX + 1))
	BASE=$(basename "$W")
	COMMIT_OF="${BASE#code-insiders-}"
	if [ "$COMMIT_OF" = "$BASE" ]; then
		COMMIT_OF="${BASE#code-}"
	fi
	if [ "$INDEX" -le "$KEEP" ] && [ -n "$COMMIT_OF" ]; then
		if [ -x "$REAL_DIR/$BASE" ]; then
			log "保留: $BASE（真身就绪）"
		else
			if [ "$BASE" = "$CURRENT_CLI" ]; then
				DL_QUALITY="$CHANNEL"
			else
				case "$BASE" in
					code-insiders-*) DL_QUALITY='insider' ;;
					*) DL_QUALITY='stable' ;;
				esac
			fi
			log "保留: $BASE（需下载真身）"
			if download_real "$COMMIT_OF" "$DL_QUALITY" "$REAL_DIR/$BASE"; then
				log '  真身下载并校验成功'
			else
				log '  真身下载失败（连接时包装脚本会自愈重试）'
			fi
		fi
	else
		rm -f "$W" "$REAL_DIR/$BASE"
		log "剪枝: $BASE"
	fi
done

# 6) 校验：包装脚本必须能透传 --version，真身必须是可执行 ELF
WRAP_COUNT=$(ls -1 "$DATA_DIR"/code-* 2>/dev/null | grep -vc -E '\.(real|tmp)$' || true)
REAL_COUNT=$(ls -1 "$REAL_DIR"/code-* 2>/dev/null | wc -l || true)
VERIFY_OUT=$("$DATA_DIR/$CURRENT_CLI" --version 2>&1 | head -1 || true)
log "校验 $CURRENT_CLI => $VERIFY_OUT"
log "部署完成。数据目录包装脚本 $WRAP_COUNT 个（少于 GC 阈值 6），真身 $REAL_COUNT 个，真身目录 $REAL_DIR"
