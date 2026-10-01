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

# ===== 旧 glibc 兼容性验证（官方 VSCODE_SERVER_CUSTOM_GLIBC_* 妥协方案）=====
# 注意：本脚本绝不自行 patchelf 修改 server 二进制——那是 Remote-SSH CLI 连接时的官方职责
# （CLI 读 VSCODE_SERVER_CUSTOM_GLIBC_LINKER/PATH/PATCHELF_PATH 三个环境变量自行 patch）。
# 实测自行 patch 新版 node（v24，4MB 对齐段）会被 patchelf 静默写坏——exit 0 但二进制损坏，
# 且残留的错误 interpreter 会让官方 CLI 误判“已 patch”而跳过修复。
# 这里只用 loader 显式加载的方式验证 sysroot 库能否支撑 server 的 node 运行（不修改任何文件）。
verify_sysroot() {
	[ -n "$SYSROOT" ] || return 0
	LOADER_REAL=$(find "$SYSROOT/glibc" -name 'ld-*.so' -type f 2>/dev/null | head -1)
	if [ -z "$LOADER_REAL" ]; then
		log '警告: sysroot 缺少 ld 实体文件，跳过验证（Remote-SSH 连接时将自行处理）。'
		return 0
	fi
	LIBDIR=$(dirname "$LOADER_REAL")
	if "$LOADER_REAL" --library-path "$LIBDIR" "$INSTALL_DIR/node" --version >/dev/null 2>&1; then
		log "sysroot 验证通过：node 可经 sysroot loader 正常启动，Remote-SSH 连接时将自动 patch server。"
	else
		log '警告: sysroot loader 验证 node 失败，Remote-SSH 连接可能报 glibc 先决条件错误。'
	fi
}

echo "准备安装 VS Code 远程服务，提交号: $COMMIT"
echo "发布通道: $CHANNEL"
echo "自动检测到的系统架构: $ARCH"
echo "自动检测到的安装目录: $INSTALL_DIR"
echo "下载工具: $DOWNLOADER"
echo "CLI 下载地址: $CLI_URL"

# ===== 安装远程 CLI（Remote-SSH 引导的启动入口，server 由它拉起，二者缺一不可；仅缺失时补装，压缩包约 30MB 直接整包下载，失败按递增间隔无限重试） =====
install_cli() {
	if [ -f "$CLI_ON_DISK" ]; then
		log "CLI 已存在，跳过安装: $CLI_ON_DISK"
		return 0
	fi

	CLI_TAR="$DATA_DIR/vscode-cli-$COMMIT.tar.gz"
	CLI_ATTEMPT=0
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		if log "开始下载远程 CLI（第 $CLI_ATTEMPT 次尝试）: $CLI_URL" && download_file "$CLI_URL" "$CLI_TAR" && [ -s "$CLI_TAR" ]; then
			CLI_TMP="$DATA_DIR/cli-unpack-$$"
			rm -rf "$CLI_TMP"
			mkdir -p "$CLI_TMP"
			if tar -xzf "$CLI_TAR" -C "$CLI_TMP" && [ -f "$CLI_TMP/$CLI_BASE_NAME" ]; then
				mv "$CLI_TMP/$CLI_BASE_NAME" "$CLI_ON_DISK"
				chmod +x "$CLI_ON_DISK"
				rm -rf "$CLI_TMP" "$CLI_TAR"
				log "远程 CLI 安装完成: $CLI_ON_DISK"
				return 0
			fi
			log "CLI 压缩包内容异常，清理后重试。"
			rm -rf "$CLI_TMP" "$CLI_TAR"
		else
			rm -f "$CLI_TAR"
		fi
		sleep "$CLI_ATTEMPT"
	done
}

# ===== 停止正在运行的旧版服务进程 =====
if command -v pkill >/dev/null 2>&1; then
	pkill -f "$COMMIT" 2>/dev/null || true
fi

# ===== CLI 下载器已在上方确定，此处先补 CLI 再处理 server =====
install_cli

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

# ===== 下载原语与远程自下载循环（无限重试 + 双备用地址，成功后写 REMOTE_DONE 标记） =====
download_file() {
	url="$1"
	output="$2"
	if [ "$DOWNLOADER" = 'curl' ]; then
		curl -fL --connect-timeout 30 -o "$output" "$url"
	else
		wget -q -O "$output" "$url"
	fi
}

run_remote_download() {
	ATTEMPT=0
	WAIT_SECONDS=0
	# 无限重试：第 1 次失败后等 1 秒，第 2 次失败后等 2 秒，依此类推，每多重试一次多等 1 秒
	while true; do
		ATTEMPT=$((ATTEMPT + 1))
		if [ "$ATTEMPT" -gt 1 ]; then
			WAIT_SECONDS=$((ATTEMPT - 1))
			log "上次下载失败，等待 $WAIT_SECONDS 秒后开始第 $ATTEMPT 次重试..."
			sleep "$WAIT_SECONDS"
		fi
		for URL in "$URL_PRIMARY" "$URL_FALLBACK"; do
			log "开始下载: $URL"
			if download_file "$URL" "$REMOTE_PKG" && [ -s "$REMOTE_PKG" ]; then
				touch "$REMOTE_DONE"
				return 0
			fi
		done
		log '本次下载失败，清理残留文件。'
		rm -f "$REMOTE_PKG"
	done
}

if [ -n "$STAGING" ]; then
	# ===== 竞速模式：远程自下载（后台）与本地下载+上传（由本地模块负责）并行，先完成者获胜 =====
	mkdir -p "$STAGING"
	REMOTE_PKG="$STAGING/REMOTE.tar.gz"
	REMOTE_DONE="$STAGING/REMOTE_DONE"
	# 本地完成标记带远程实际架构后缀：本地供给侧若架构判断错误则永远对不上，避免错误架构的包获胜
	LOCAL_DONE="$STAGING/LOCAL_DONE.$ARCH"
	LOCAL_PKG="$STAGING/LOCAL.tar.gz"
	# 清理本端上一轮残留；LOCAL_DONE/LOCAL_PKG 由本地供给任务管理，不在此处删（可能已先于本脚本完成）
	rm -f "$REMOTE_PKG" "$REMOTE_DONE" "$STAGING/LOCAL_CANCEL"

	log '竞速模式：远程自下载与本地下载+上传并行，先完成者用于安装。'
	DL_PID=''
	if [ -n "$DOWNLOADER" ]; then
		run_remote_download &
		DL_PID=$!
	else
		log '远程缺少 curl/wget，本端不参与下载，只等待本地供给。'
	fi

	ELAPSED=0
	WINNER=''
	while true; do
		if [ -f "$REMOTE_DONE" ]; then
			WINNER='remote'
			break
		fi
		if [ -f "$LOCAL_DONE" ]; then
			WINNER='local'
			break
		fi
		sleep 1
		ELAPSED=$((ELAPSED + 1))
		if [ $((ELAPSED % 30)) -eq 0 ]; then
			RSIZE=0
			if [ -f "$REMOTE_PKG" ]; then
				RSIZE=$(wc -c < "$REMOTE_PKG" 2>/dev/null | tr -d ' ')
			fi
			LSIZE=0
			# 本地供给包：上传完成前为 LOCAL.tar.gz.uploading（scp 写入），完成后更名为 LOCAL.tar.gz
			if [ -f "$LOCAL_PKG" ]; then
				LSIZE=$(wc -c < "$LOCAL_PKG" 2>/dev/null | tr -d ' ')
			elif [ -f "$LOCAL_PKG.uploading" ]; then
				LSIZE=$(wc -c < "$LOCAL_PKG.uploading" 2>/dev/null | tr -d ' ')
			fi
			log "竞速等待 ${ELAPSED}s：远程侧已下 ${RSIZE} 字节，本地侧已到 ${LSIZE} 字节。"
		fi
	done

	# 胜负已分：写取消标记让本地供给任务停止后续动作，并终止远程后台下载
	touch "$STAGING/LOCAL_CANCEL"
	if [ -n "$DL_PID" ]; then
		if command -v pkill >/dev/null 2>&1; then
			pkill -P "$DL_PID" 2>/dev/null || true
		fi
		kill "$DL_PID" 2>/dev/null || true
		wait "$DL_PID" 2>/dev/null || true
	fi

	if [ "$WINNER" = 'local' ]; then
		PACKAGE_PATH="$STAGING/LOCAL.tar.gz"
		log '竞速获胜：本地供给的压缩包，开始解压。'
	else
		PACKAGE_PATH="$REMOTE_PKG"
		log '竞速获胜：远程自下载的压缩包，开始解压。'
	fi
else
	# ===== 未启用竞速：保持原有前台单独下载 =====
	REMOTE_PKG="$INSTALL_DIR/vscode-server-download-$$.tar.gz"
	REMOTE_DONE="$INSTALL_DIR/vscode-server-download-$$.done"
	run_remote_download
	PACKAGE_PATH="$REMOTE_PKG"
	rm -f "$REMOTE_DONE"
	echo '下载完成，开始解压。'
fi

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
