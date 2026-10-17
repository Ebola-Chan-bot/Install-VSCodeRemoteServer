#!/bin/sh
# 远程安装脚本（Linux 版）
# 兼容 POSIX sh（bash/dash/ash），此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。
# 注意：bash 变量名不支持非 ASCII 字符，故变量使用英文，注释与输出保持中文。

set -eu

# ===== 由主模块替换的参数 =====
COMMIT='__提交号__'
CHANNEL='__发布通道__'
# 竞速暂存目录：本地模块与远程脚本约定在同一目录交换压缩包与标记文件；空串表示未启用竞速，回退远程单独下载
STAGING='__暂存目录__'
# 兼容性 sysroot 目录（官方旧 glibc 妥协方案）：非空时用其中的 patchelf 把 server 内所有 ELF 二进制的解释器与 rpath 指向 sysroot；空串表示无需 patch
SYSROOT='__兼容性目录__'

# ===== 自动检测系统架构 =====
detect_arch() {
	MACHINE=$(uname -m)
	case "$MACHINE" in
		x86_64 | amd64)
			echo 'linux-x64'
			;;
		aarch64 | arm64)
			echo 'linux-arm64'
			;;
		armv7l | armv6l | armhf | arm)
			echo 'linux-armhf'
			;;
		*)
			echo "暂不支持的远程系统架构: $MACHINE" >&2
			exit 1
			;;
	esac
}

ARCH=$(detect_arch)

# ===== 推导安装目录（新版 exec server 布局: <数据目录>/cli/servers/<质量名>-<提交号>/server，旧 bin 布局已弃用） =====
if [ "$CHANNEL" = 'insider' ]; then
	DATA_DIR="$HOME/.vscode-server-insiders"
	QUALITY='Insiders'
else
	DATA_DIR="$HOME/.vscode-server"
	QUALITY='Stable'
fi
INSTALL_DIR="$DATA_DIR/cli/servers/$QUALITY-$COMMIT/server"

# ===== CLI 名称与下载 artifact（Remote-SSH 引导契约：数据根目录需存在 <cli名>-<提交号>，cli 名稳定版 code、预览版 code-insiders；x64/arm64 用 cli-alpine-<架构>，armhf 用 cli-linux-armhf） =====
if [ "$CHANNEL" = 'insider' ]; then
	CLI_BASE_NAME='code-insiders'
else
	CLI_BASE_NAME='code'
fi
CLI_ON_DISK="$DATA_DIR/$CLI_BASE_NAME-$COMMIT"
if [ "$ARCH" = 'linux-armhf' ]; then
	CLI_ARTIFACT='cli-linux-armhf'
else
	CLI_ARTIFACT="cli-alpine-$(echo "$ARCH" | sed 's/^linux-//')"
fi
CLI_URL="https://update.code.visualstudio.com/commit:$COMMIT/$CLI_ARTIFACT/$CHANNEL"

# ===== 生成候选下载地址（第一个失败则尝试下一个） =====
URL_PRIMARY="https://vscode.download.prss.microsoft.com/dbazure/download/$CHANNEL/$COMMIT/vscode-server-$ARCH.tar.gz"
URL_FALLBACK="https://update.code.visualstudio.com/commit:$COMMIT/server-$ARCH/$CHANNEL"

# ===== 下载器选择：优先 curl，回退 wget =====
# 竞速模式下即使两者都没有也可以只等本地供给，故仅在非竞速时视为致命错误
DOWNLOADER=''
if command -v curl >/dev/null 2>&1; then
	DOWNLOADER='curl'
elif command -v wget >/dev/null 2>&1; then
	DOWNLOADER='wget'
elif [ -z "$STAGING" ]; then
	echo '错误: 远程主机缺少 curl 或 wget，无法下载 VS Code Server。' >&2
	exit 1
fi

# 时间戳输出辅助函数
log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ===== 下载原语（sh 逐行解释执行，函数必须定义在所有调用点之前：install_cli 在下方即会调用）=====
download_file() {
	url="$1"
	output="$2"
	if [ "$DOWNLOADER" = 'curl' ]; then
		# curl 默认往 stderr 打英文进度条（回车刷屏文案），会污染输出流；-s 静音进度条、-S 仍显示错误
		curl -fsSL --connect-timeout 30 -o "$output" "$url"
	else
		wget -q -O "$output" "$url"
	fi
}

# ===== 旧 glibc 兼容性验证（官方 VSCODE_SERVER_CUSTOM_GLIBC_* 妥协方案）=====
# 注意：本脚本绝不自行 patchelf 修改 server 二进制——那是 Remote-SSH CLI 连接时的官方职责（CLI 读 VSCODE_SERVER_CUSTOM_GLIBC_LINKER/PATH/PATCHELF_PATH 三个环境变量自行 patch）。实测自行 patch 新版 node（v24，4MB 对齐段）会被 patchelf 静默写坏——exit 0 但二进制损坏，且残留的错误 interpreter 会让官方 CLI 误判“已 patch”而跳过修复。这里只用 loader 显式加载的方式验证 sysroot 库能否支撑 server 的 node 运行（不修改任何文件）。
verify_sysroot() {
	[ -n "$SYSROOT" ] || return 0
	LOADER_REAL=$(find "$SYSROOT/glibc" -name 'ld-*.so' -type f 2>/dev/null | head -1)
	if [ -z "$LOADER_REAL" ]; then
		log '警告: sysroot 缺少 ld 实体文件，跳过验证（Remote-SSH 连接时将自行处理）。'
		return 0
	fi
	LIBDIR=$(dirname "$LOADER_REAL")
	VERIFY_OUT=$("$LOADER_REAL" --library-path "$LIBDIR" "$INSTALL_DIR/node" --version 2>&1) && VERIFY_RC=0 || VERIFY_RC=$?
	if [ "$VERIFY_RC" -eq 0 ]; then
		log "sysroot 验证通过：node 可经 sysroot loader 正常启动，Remote-SSH 连接时将自动 patch server。"
	else
		log "警告: sysroot loader 验证 node 失败（$(echo "$VERIFY_OUT" | tr '\n' ' ')）。Remote-SSH 连接可能报 glibc 先决条件错误；若含 kernel too old 则是远程内核低于 glibc 2.28 要求的 3.2，sysroot 妥协方案无解。"
	fi
}

echo "准备安装 VS Code 远程服务，提交号: $COMMIT"
echo "发布通道: $CHANNEL"
echo "自动检测到的系统架构: $ARCH"
echo "自动检测到的安装目录: $INSTALL_DIR"
echo "下载工具: $DOWNLOADER"
echo "CLI 下载地址: $CLI_URL"

# ===== 下载与竞速原语（sh 逐行解释执行，函数必须定义在所有调用点之前）=====

# 远程自下载 server 压缩包（无限重试 + 双备用地址）：$1=包路径 $2=完成标记；竞速模式下后台拉起，决出后被整体终止，故无需取消检查
run_remote_download() {
	PKG_OUT="$1"
	DONE_MARK="$2"
	CLI_ATTEMPT=0
	WAIT_SECONDS=0
	# 无限重试：第 1 次失败后等 1 秒，第 2 次失败后等 2 秒，依此类推，每多重试一次多等 1 秒
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		if [ "$CLI_ATTEMPT" -gt 1 ]; then
			WAIT_SECONDS=$((CLI_ATTEMPT - 1))
			log "上次下载失败，等待 $WAIT_SECONDS 秒后开始第 $CLI_ATTEMPT 次重试..."
			sleep "$WAIT_SECONDS"
		fi
		for URL in "$URL_PRIMARY" "$URL_FALLBACK"; do
			log "开始下载: $URL"
			if download_file "$URL" "$PKG_OUT" && [ -s "$PKG_OUT" ]; then
				# gzip 完整性校验：流式下载读到底不等于传完整，截断包解压只会报晦涩错误，坏包弃用换源重下
				if gzip -t "$PKG_OUT" 2>/dev/null; then
					touch "$DONE_MARK"
					return 0
				fi
				log '压缩包完整性校验未通过（疑似截断），弃用重下。'
				rm -f "$PKG_OUT"
			fi
		done
		log '本次下载失败，清理残留文件。'
		rm -f "$PKG_OUT"
	done
}

# 远程自下载 CLI 压缩包（竞速模式下后台拉起）：$1=包路径 $2=完成标记；同样无限重试，决出后被整体终止
run_remote_cli_download() {
	PKG_OUT="$1"
	DONE_MARK="$2"
	CLI_ATTEMPT=0
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		if [ "$CLI_ATTEMPT" -gt 1 ]; then
			WAIT_SECONDS=$((CLI_ATTEMPT - 1))
			log "CLI 上次下载失败，等待 $WAIT_SECONDS 秒后开始第 $CLI_ATTEMPT 次重试..."
			sleep "$WAIT_SECONDS"
		fi
		log "开始下载远程 CLI: $CLI_URL"
		if download_file "$CLI_URL" "$PKG_OUT" && [ -s "$PKG_OUT" ]; then
			if gzip -t "$PKG_OUT" 2>/dev/null; then
				touch "$DONE_MARK"
				return 0
			fi
			log 'CLI 压缩包完整性校验未通过（疑似截断），弃用重下。'
			rm -f "$PKG_OUT"
		fi
		log '本次 CLI 下载失败，清理残留文件。'
		rm -f "$PKG_OUT"
	done
}

# 竞速单个产物：后台远程自下载 与 本地下载+上传（由本地模块负责）并行，先完成者获胜。$1=产物名 $2=远程包路径 $3=远程完成标记 $4=本地包路径 $5=本地完成标记 $6=本地取消标记 $7=远程后台下载函数名（空串=远程不下载）
# 返回后 RACE_WINNER_SIDE（remote/local）与 RACE_WINNER_PKG（获胜包路径）有效
race_artifact() {
	RACE_WINNER_SIDE=''
	RACE_WINNER_PKG=''
	# 清理本端上一轮残留；本地包与本地标记由本地供给任务管理，不在此处删（可能已先于本脚本完成）
	rm -f "$2" "$3" "$6"
	log "$1 竞速：远程自下载与本地下载+上传并行，先完成者用于安装。"
	DL_PID=''
	if [ -n "$7" ]; then
		"$7" "$2" "$3" >/dev/null 2>&1 &
		DL_PID=$!
	else
		log "$1：远程缺少 curl/wget，本端不参与下载，只等待本地供给。"
	fi

	ELAPSED=0
	# 竞速等待心跳没有产物总大小可比对，无法估算剩余时间，报告周期只增不减（每次报告后加 1 秒）
	REPORT_PERIOD=1
	NEXT_REPORT=$REPORT_PERIOD
	while true; do
		if [ -f "$3" ]; then
			RACE_WINNER_SIDE='remote'
			break
		fi
		if [ -f "$5" ]; then
			RACE_WINNER_SIDE='local'
			break
		fi
		sleep 1
		ELAPSED=$((ELAPSED + 1))
		if [ "$ELAPSED" -ge "$NEXT_REPORT" ]; then
			if [ -n "$7" ]; then
				RSIZE=0
				if [ -f "$2" ]; then
					RSIZE=$(wc -c < "$2" 2>/dev/null | tr -d ' ')
				fi
				# 心跳并入远程下载进度句式（无产物总大小可比对，只报已传字节数）；进度行不带内嵌时间戳，故不经 log 前缀
				echo "远程下载进度：已传 ${RSIZE} 字节（竞速等待 ${ELAPSED}s）"
			else
				log "$1 竞速等待 ${ELAPSED}s：远程侧不参与下载，等待本地供给。"
			fi
			REPORT_PERIOD=$((REPORT_PERIOD + 1))
			NEXT_REPORT=$((ELAPSED + REPORT_PERIOD))
		fi
	done

	# 胜负已分：写该产物的取消标记让本地供给任务停止该产物的后续动作，并终止远程后台下载
	touch "$6"
	if [ -n "$DL_PID" ]; then
		if command -v pkill >/dev/null 2>&1; then
			pkill -P "$DL_PID" 2>/dev/null || true
		fi
		kill "$DL_PID" 2>/dev/null || true
		wait "$DL_PID" 2>/dev/null || true
	fi

	if [ "$RACE_WINNER_SIDE" = 'local' ]; then
		RACE_WINNER_PKG="$4"
		log "竞速决出（$1）：本地供给的压缩包。"
	else
		RACE_WINNER_PKG="$2"
		log "竞速决出（$1）：远程自下载的压缩包。"
	fi
}

# 解包 CLI 压缩包并按引导契约落到正式名（包内为单个 code[-insiders] 可执行文件）；$1=压缩包路径
unpack_cli_package() {
	# 并行官方引导可能已把 CLI 装好（甚至已启动），此时安装实际已完成，直接收尾
	if [ -f "$CLI_ON_DISK" ]; then
		log "CLI 已就位（并行安装完成），跳过安装: $CLI_ON_DISK"
		return 0
	fi
	CLI_TMP="$DATA_DIR/cli-unpack-$$"
	rm -rf "$CLI_TMP"
	mkdir -p "$CLI_TMP"
	if tar -xzf "$1" -C "$CLI_TMP" && [ -f "$CLI_TMP/$CLI_BASE_NAME" ]; then
		mv "$CLI_TMP/$CLI_BASE_NAME" "$CLI_ON_DISK"
		chmod +x "$CLI_ON_DISK"
		rm -rf "$CLI_TMP" "$1"
		log "远程 CLI 安装完成: $CLI_ON_DISK"
		return 0
	fi
	log 'CLI 压缩包内容异常，已清理。'
	rm -rf "$CLI_TMP" "$1"
	return 1
}

# ===== 非竞速模式的 CLI 补装（前台无限重试；竞速模式的 CLI 由竞速供给，不走这里）：仅缺失时补装，压缩包约 30MB 直接整包下载 =====
install_cli() {
	if [ -f "$CLI_ON_DISK" ]; then
		log "CLI 已存在，跳过安装: $CLI_ON_DISK"
		return 0
	fi

	CLI_TAR="$DATA_DIR/vscode-cli-$COMMIT.tar.gz"
	CLI_ATTEMPT=0
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		# 每轮重试前复查：官方引导可能已并行把 CLI 装好，此时安装实际已完成，直接收尾退出，不再无谓下载重试
		if [ -f "$CLI_ON_DISK" ]; then
			log "CLI 已就位（并行安装完成），跳过安装: $CLI_ON_DISK"
			return 0
		fi
		if log "开始下载远程 CLI（第 $CLI_ATTEMPT 次尝试）: $CLI_URL" && download_file "$CLI_URL" "$CLI_TAR" && [ -s "$CLI_TAR" ]; then
			unpack_cli_package "$CLI_TAR" && return 0
		else
			rm -f "$CLI_TAR"
		fi
		sleep "$CLI_ATTEMPT"
	done
}

# ===== 历史版本回收（每次连接顺手做）：客户端只认自己提交号的 server，更新后的客户端不会回头调用旧版本，旧版本留着只吃磁盘（每套约 250MB） =====
# 保留三类：本次提交号的版本、有进程正在使用的版本（命令行含该版本提交号，可能是活会话或保活 daemon）、按目录修改时间最新的 5 个（多台机器/回滚场景的缓冲，与官方启动入口 GC 的保留量一致）；其余一律删除。
# 目录修改时间当作最后使用时间，每次连接把当前版本目录 touch 成此刻；Stable 与 Insiders 是两个客户端各自的领地，两棵数据目录同规则各清各的。
cleanup_old_versions() {
	for DATA_ROOT in "$HOME/.vscode-server" "$HOME/.vscode-server-insiders"; do
		[ -d "$DATA_ROOT" ] || continue
		LIST_TMP="$DATA_ROOT/.vsi-gc-list.$$"
		rm -f "$DATA_ROOT"/.vsi-gc-list.* 2>/dev/null || true
		: > "$LIST_TMP"
		for DIR in "$DATA_ROOT"/cli/servers/* "$DATA_ROOT"/bin/*; do
			[ -d "$DIR" ] || continue
			NAME=${DIR##*/}
			case "$NAME" in
				[0-9a-fA-F]*) VER_COMMIT=$NAME ;;
				*) VER_COMMIT=${NAME#*-} ;;
			esac
			case "$VER_COMMIT" in
				'' | *[!0-9a-fA-F]*) continue ;;
			esac
			[ ${#VER_COMMIT} -eq 40 ] || continue
			echo "$(date -r "$DIR" +%s 2>/dev/null || echo 0) $DIR $VER_COMMIT" >> "$LIST_TMP"
		done
		sort -rn "$LIST_TMP" > "$LIST_TMP.sorted"
		KEPT=0
		while read -r TS DIR VER_COMMIT; do
			if [ "$VER_COMMIT" = "$COMMIT" ]; then
				touch "$DIR" 2>/dev/null || true
				continue
			fi
			# 有进程命令行引用该版本提交号即视为在用，绝不删（活会话/保活 daemon 的路径里带着提交号）
			if grep -qs -- "$VER_COMMIT" /proc/[0-9]*/cmdline 2>/dev/null; then continue; fi
			KEPT=$((KEPT + 1))
			if [ "$KEPT" -le 5 ]; then continue; fi
			rm -rf "$DIR"
			log "已清理历史版本服务端: ${DIR##*/}"
		done < "$LIST_TMP.sorted"
		rm -f "$LIST_TMP" "$LIST_TMP.sorted"
	done
}

# ===== 判定待装产物：已就位的产物不参与竞速，避免无谓的下载与上传 =====
NEED_CLI=1
if [ -f "$CLI_ON_DISK" ]; then
	NEED_CLI=0
fi
NEED_SERVER=1
if [ -f "$INSTALL_DIR/product.json" ] && [ -d "$INSTALL_DIR/bin" ]; then
	NEED_SERVER=0
fi

# ===== 历史版本回收：每次连接顺手清旧版（先于下载，磁盘紧张时先腾地方） =====
cleanup_old_versions || true

# ===== 仅当确有产物需要重装时才停止正在运行的旧版服务进程 =====
# 无条件 pkill -f "$COMMIT" 会把命令行含提交号的 command-shell daemon 与 VS Code Server 一并杀掉（提交号就嵌在它们的路径里），于是每次连接的接管安装都会打死上次会话正在服务的进程，重连与多开窗口互相残杀。产物齐备时没有任何重装动作，绝不碰运行中的进程；真正要重装产物时才清理旧进程，避免旧进程占住将被覆盖的文件。
if [ "$NEED_CLI" = '1' ] || [ "$NEED_SERVER" = '1' ]; then
	if command -v pkill >/dev/null 2>&1; then
		pkill -f "$COMMIT" 2>/dev/null || true
	fi
fi

CLI_WINNER_PKG=''
SERVER_WINNER_PKG=''
if [ -n "$STAGING" ]; then
	# ===== 竞速模式：每个缺失产物各竞速一次（本地下载+上传 vs 远程自下载，先完成者获胜），CLI 与服务端独立判胜、互不拖累 =====
	# 单边断网时由另一边补上：远端连不上下载服务器就等本地供给，本地下载失败就等远程自下载
	mkdir -p "$STAGING"
	RACE_CLI_DL_FN=''
	RACE_SERVER_DL_FN=''
	if [ -n "$DOWNLOADER" ]; then
		RACE_CLI_DL_FN='run_remote_cli_download'
		RACE_SERVER_DL_FN='run_remote_download'
	fi
	if [ "$NEED_CLI" = '1' ]; then
		race_artifact 'CLI' "$STAGING/REMOTE_CLI.tar.gz" "$STAGING/REMOTE_CLI_DONE" "$STAGING/LOCAL_CLI.tar.gz" "$STAGING/LOCAL_CLI_DONE.$ARCH" "$STAGING/LOCAL_CLI_CANCEL" "$RACE_CLI_DL_FN"
		CLI_WINNER_PKG="$RACE_WINNER_PKG"
	fi
	if [ "$NEED_SERVER" = '1' ]; then
		race_artifact '服务端' "$STAGING/REMOTE.tar.gz" "$STAGING/REMOTE_DONE" "$STAGING/LOCAL.tar.gz" "$STAGING/LOCAL_DONE.$ARCH" "$STAGING/LOCAL_CANCEL" "$RACE_SERVER_DL_FN"
		SERVER_WINNER_PKG="$RACE_WINNER_PKG"
	fi
	# 全部产物竞速决出：该行触发主流程立即击杀本地供给进程树（零轮询即时取消）
	echo '竞速获胜：全部产物已就位，开始安装。'
fi

# ===== 安装 CLI（Remote-SSH 引导的启动入口，server 由它拉起，二者缺一不可）=====
if [ "$NEED_CLI" = '0' ]; then
	log "CLI 已存在，跳过安装: $CLI_ON_DISK"
elif [ -n "$STAGING" ]; then
	if ! unpack_cli_package "$CLI_WINNER_PKG"; then
		echo "错误: 竞速决出的 CLI 压缩包无法解包: $CLI_WINNER_PKG" >&2
		exit 1
	fi
else
	install_cli
fi

# 同提交号且结构完整（product.json 与 bin 并存）的 server 直接复用，避免重复下载
if [ -f "$INSTALL_DIR/product.json" ] && [ -d "$INSTALL_DIR/bin" ]; then
	log "同提交号的 Server 已完整安装，跳过下载与解压: $INSTALL_DIR"
	verify_sysroot
	ls -la "$INSTALL_DIR"
	exit 0
fi

# ===== 清理并重建安装目录 =====
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ -n "$STAGING" ]; then
	# 竞速决出的服务端压缩包（若服务端已就位则未竞速，上面的复用判定已提前收尾）
	if [ -z "$SERVER_WINNER_PKG" ] || [ ! -f "$SERVER_WINNER_PKG" ]; then
		echo "错误: 竞速未产出服务端压缩包: $SERVER_WINNER_PKG" >&2
		exit 1
	fi
	PACKAGE_PATH="$SERVER_WINNER_PKG"
else
	# ===== 未启用竞速：保持原有前台单独下载 =====
	REMOTE_PKG="$INSTALL_DIR/vscode-server-download-$$.tar.gz"
	REMOTE_DONE="$INSTALL_DIR/vscode-server-download-$$.done"
	run_remote_download "$REMOTE_PKG" "$REMOTE_DONE"
	PACKAGE_PATH="$REMOTE_PKG"
	rm -f "$REMOTE_DONE"
fi

# ===== 包完整性校验与兑底：截断包解压只会报晦涩错误，gzip -t 一票否决，坏包换另一侧的包，全坏则前台重下自愈 =====
if ! gzip -t "$PACKAGE_PATH" 2>/dev/null; then
	log "压缩包完整性校验未通过（疑似截断），弃用: $PACKAGE_PATH"
	rm -f "$PACKAGE_PATH"
	PACKAGE_PATH=''
	if [ -n "$STAGING" ]; then
		for CAND in "$STAGING/LOCAL.tar.gz" "$STAGING/REMOTE.tar.gz"; do
			if [ -f "$CAND" ] && gzip -t "$CAND" 2>/dev/null; then
				PACKAGE_PATH="$CAND"
				log "改用另一侧的压缩包: $CAND"
				break
			fi
			rm -f "$CAND"
		done
	fi
	if [ -z "$PACKAGE_PATH" ]; then
		log '所有候选压缩包均不可用，前台重新下载。'
		FG_PKG="$INSTALL_DIR/vscode-server-download-$$.tar.gz"
		run_remote_download "$FG_PKG" "$INSTALL_DIR/vscode-server-download-$$.done"
		PACKAGE_PATH="$FG_PKG"
	fi
fi

echo '下载完成，开始解压。'

# ===== 解压并铺平包装目录 =====
tar -xzf "$PACKAGE_PATH" -C "$INSTALL_DIR"

# 压缩包内通常为 vscode-server-<架构>/ 单层包装目录，将其内容上移一级
WRAPPER_COUNT=0
WRAPPER_DIR=''
for ITEM in "$INSTALL_DIR"/* "$INSTALL_DIR"/.[!.]*; do
	[ -e "$ITEM" ] || continue
	if [ -d "$ITEM" ] && [ "$(basename "$ITEM")" != 'vscode-server-download-'* ]; then
		WRAPPER_COUNT=$((WRAPPER_COUNT + 1))
		WRAPPER_DIR="$ITEM"
	fi
done

# 若压缩包自带单层目录（且旁边只有压缩包），将该目录内容上移
if [ "$WRAPPER_COUNT" -ge 1 ]; then
	case "$(basename "$WRAPPER_DIR")" in
		vscode-server-*)
			echo "检测到包装目录 $(basename "$WRAPPER_DIR")，正在铺平目录结构。"
			# 顶层包装目录下无隐藏文件（实测 vscode-server-linux-x64.tar.gz 确认），直接移动全部内容
			mv "$WRAPPER_DIR"/* "$INSTALL_DIR/"
			rmdir "$WRAPPER_DIR" 2>/dev/null || rm -rf "$WRAPPER_DIR"
			;;
	esac
fi

rm -f "$PACKAGE_PATH"

# ===== 关键文件存在性检查 =====
# 可执行文件名随发布通道不同：稳定版 code-server，预览版 code-server-insiders
if [ "$CHANNEL" = 'insider' ]; then
	SERVER_BINARY='code-server-insiders'
else
	SERVER_BINARY='code-server'
fi

echo "检查关键文件: $INSTALL_DIR/bin/$SERVER_BINARY"
if [ ! -f "$INSTALL_DIR/bin/$SERVER_BINARY" ]; then
	echo "错误: 解压后未找到 bin/$SERVER_BINARY，安装可能不完整。" >&2
	exit 1
fi

# 旧 glibc 系统：验证 sysroot 可支撑 node 运行（patch 由 Remote-SSH 连接时自行完成）
verify_sysroot

# 竞速暂存目录用完即清（双保险：本地模块收尾时还会再清一次）
if [ -n "$STAGING" ]; then
	rm -rf "$STAGING" 2>/dev/null || true
fi

echo '安装完成，当前目录内容如下。'
ls -la "$INSTALL_DIR"
