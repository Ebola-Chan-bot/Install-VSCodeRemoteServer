#!/bin/sh
# 包装脚本版本: WRAPPER-V4-DOUBLE-FORK
# VSCODE-PERSISTENT-WRAPPER-v2 : 让 exec server 的 command-shell 脱离 sshd 会话，并把看门狗父进程钉死为 PID 1
# 由 安装-VSCode服务保活 自动生成；还原方式：安装-VSCode服务保活 -远程主机 <主机> -移除
# 真实二进制放数据目录之外（官方引导脚本的 GC 会按文件名清理数据目录，放在里面必被误删）
# PERSIST_DIR 的真实路径由 服务保活部署脚本.sh 的 write_wrapper 生成时填入
PERSIST_DIR='@@PERSIST_DIR@@'
REAL_DIR="$PERSIST_DIR/real"
SELF_NAME=$(basename "$0")
REAL="$REAL_DIR/$SELF_NAME"
WLOG="$PERSIST_DIR/wrapper.log"

# 追加一行带时间戳的记录到 wrapper.log；写失败静默忽略（保活日志不应影响启动流程）
log() {
	printf '[保活wrapper] %s %s\n' "$(date '+%F %T')" "$*" >>"$WLOG" 2>/dev/null || true
}

case "$SELF_NAME" in
	code-insiders-*)
		SELF_COMMIT=${SELF_NAME#code-insiders-}
		SELF_QUALITY=insider
		;;
	*)
		SELF_COMMIT=${SELF_NAME#code-}
		SELF_QUALITY=stable
		;;
esac

# 自愈：真身缺失时现场下载补回（例如被误删、或首次部署时数据目录尚无该提交号），全程记入 wrapper.log
if [ ! -x "$REAL" ]; then
	{
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SELF_NAME: 真实 CLI 缺失，开始自愈下载 ($SELF_COMMIT/$SELF_QUALITY)"
		MACHINE=$(uname -m)
		case "$MACHINE" in
			x86_64 | amd64) ARTIFACT='cli-alpine-x64' ;;
			aarch64 | arm64) ARTIFACT='cli-alpine-arm64' ;;
			armv7l | armv6l | armhf | arm) ARTIFACT='cli-linux-armhf' ;;
			*) ARTIFACT='' ;;
		esac
		if [ -n "$ARTIFACT" ]; then
			URL="https://update.code.visualstudio.com/commit:$SELF_COMMIT/$ARTIFACT/$SELF_QUALITY"
			TMP="$REAL.$$"
			mkdir -p "$REAL_DIR"
			if command -v curl >/dev/null 2>&1; then
				curl -fsSL --connect-timeout 10 --max-time 600 -o "$TMP" "$URL"
			elif command -v wget >/dev/null 2>&1; then
				wget -q -O "$TMP" "$URL"
			else
				false
			fi
			if [ -f "$TMP" ]; then
				if [ "$SELF_QUALITY" = 'insider' ]; then
					IN_ARCHIVE='code-insiders'
				else
					IN_ARCHIVE='code'
				fi
				tar -xf "$TMP" --no-same-owner -C "$REAL_DIR" "$IN_ARCHIVE" &&
					mv -f "$REAL_DIR/$IN_ARCHIVE" "$REAL" &&
					chmod 755 "$REAL" &&
					echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SELF_NAME: 真实 CLI 已恢复"
			fi
			rm -f "$TMP"
		else
			echo "无法识别架构 $MACHINE，放弃自愈"
		fi
	} >>"$WLOG" 2>&1
	if [ ! -x "$REAL" ]; then
		echo "[保活包装] 真实 CLI 缺失且自愈失败: $REAL" >&2
		exit 127
	fi
fi

# 非 command-shell 调用（--version、--install-extension 等）原样透传，不做脱离处理
IS_CS=0
for ARG in "$@"; do
	if [ "$ARG" = 'command-shell' ]; then
		IS_CS=1
	fi
done
if [ "$IS_CS" -eq 0 ] || [ -n "${VSCODE_PERSIST_DISABLE:-}" ]; then
	exec "$REAL" "$@"
fi

# 逐个消费原参数并追加到队尾，把 --parent-process-id 的取值改写为 1（PID 1 永存），看门狗便不会随 sshd 会话死亡而自杀
REMAIN=$#
while [ "$REMAIN" -gt 0 ]; do
	ARG=$1
	shift
	REMAIN=$((REMAIN - 1))
	case "$ARG" in
		--parent-process-id)
			if [ "$REMAIN" -gt 0 ]; then
				shift
				REMAIN=$((REMAIN - 1))
			fi
			set -- "$@" --parent-process-id 1
			;;
		--parent-process-id=*)
			set -- "$@" --parent-process-id=1
			;;
		*)
			set -- "$@" "$ARG"
			;;
	esac
done

# ---- 双 fork 脱逃：子 shell 内 setsid 后台启动真身 ----
# 只用 setsid 不够：它改会话与进程组，却不改 PPID。daemon 的 PPID 仍是引导脚本那个 sh，而 sh 的父进程正是 60 分钟到期的 sshd-session，收割按祖先链清理时照样命中。
# 实测：旧 server 日志停在被收割前一刻，且无任何优雅退出记录，证明单靠 setsid 未能脱逃。
# 本机 setsid 为 util-linux 2.23，无 --fork 选项，故用子 shell 实现双 fork：子 shell 立即退出 → 真身被 init 收养（PPID=1，祖先链断裂）；setsid 另建会话与进程组。
# 对照证据：同机 tmux 因 PPID=1 已存活数十小时，而全系统无一 VS Code 服务进程活过 70 分钟。
# 真身继承 wrapper 的 stdout/stderr，仍写入引导脚本重定向的 CLI 日志文件，其中 "Listening on 127.0.0.1:<port>" 照旧能被引导脚本解析出来。
( setsid "$REAL" "$@" & )
log "已双 fork 启动 daemon（PPID=1、自建会话），参数: $*"

# wrapper 自身必须继续存活：引导脚本以 $!（即 wrapper 的 PID）做 kill -0 存活检查，若此处立即退出会被判定 "Exec server process not found" 而中止启动流程。收割来临时本壳进程随会话一起消失，真身因祖先链已断而不受影响。用 exec 把壳进程自身替换为 sleep：收割来临时它随会话一起消失，不会像 while+sleep 那样留下一个游离的子 sleep 进程。
exec sleep 2147483647
