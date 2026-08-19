#!/bin/sh
# 远程安装脚本（Linux 版）
# 兼容 POSIX sh（bash/dash/ash），此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。
# 注意：bash 变量名不支持非 ASCII 字符，故变量使用英文，注释与输出保持中文。

set -eu

# ===== 由主模块替换的参数 =====
COMMIT='__提交号__'
CHANNEL='__发布通道__'

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

# ===== 推导安装目录 =====
if [ "$CHANNEL" = 'insider' ]; then
	INSTALL_ROOT="$HOME/.vscode-server-insiders/bin"
else
	INSTALL_ROOT="$HOME/.vscode-server/bin"
fi
INSTALL_DIR="$INSTALL_ROOT/$COMMIT"
PACKAGE_PATH="$INSTALL_DIR/vscode-server-download-$$.tar.gz"

# ===== 生成候选下载地址（第一个失败则尝试下一个） =====
URL_PRIMARY="https://vscode.download.prss.microsoft.com/dbazure/download/$CHANNEL/$COMMIT/vscode-server-$ARCH.tar.gz"
URL_FALLBACK="https://update.code.visualstudio.com/commit:$COMMIT/server-$ARCH/$CHANNEL"

# ===== 下载器选择：优先 curl，回退 wget =====
DOWNLOADER=''
if command -v curl >/dev/null 2>&1; then
	DOWNLOADER='curl'
elif command -v wget >/dev/null 2>&1; then
	DOWNLOADER='wget'
else
	echo '错误: 远程主机缺少 curl 或 wget，无法下载 VS Code Server。' >&2
	exit 1
fi

# 时间戳输出辅助函数
log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

echo "准备安装 VS Code 远程服务，提交号: $COMMIT"
echo "发布通道: $CHANNEL"
echo "自动检测到的系统架构: $ARCH"
echo "自动检测到的安装目录: $INSTALL_DIR"
echo "下载工具: $DOWNLOADER"

# ===== 停止正在运行的旧版服务进程 =====
if command -v pkill >/dev/null 2>&1; then
	pkill -f "$COMMIT" 2>/dev/null || true
fi

# ===== 清理并重建安装目录 =====
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# ===== 无限重试与备用地址的下载 =====
download_file() {
	url="$1"
	output="$2"
	if [ "$DOWNLOADER" = 'curl' ]; then
		curl -fL --connect-timeout 30 -o "$output" "$url"
	else
		wget -q -O "$output" "$url"
	fi
}

ATTEMPT=0
WAIT_SECONDS=0
SUCCESS=''
# 无限重试：第 1 次失败后等 1 秒，第 2 次失败后等 2 秒，依此类推，每多重试一次多等 1 秒
while [ -z "$SUCCESS" ]; do
	ATTEMPT=$((ATTEMPT + 1))
	if [ "$ATTEMPT" -gt 1 ]; then
		WAIT_SECONDS=$((ATTEMPT - 1))
		log "上次下载失败，等待 $WAIT_SECONDS 秒后开始第 $ATTEMPT 次重试..."
		sleep "$WAIT_SECONDS"
	fi
	for URL in "$URL_PRIMARY" "$URL_FALLBACK"; do
		log "开始下载: $URL"
		if download_file "$URL" "$PACKAGE_PATH" && [ -s "$PACKAGE_PATH" ]; then
			SUCCESS='是'
			break
		fi
	done
	if [ -n "$SUCCESS" ]; then
		break
	fi
	log '本次下载失败，清理残留文件。'
	rm -f "$PACKAGE_PATH"
done

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

echo '安装完成，当前目录内容如下。'
ls -la "$INSTALL_DIR"
