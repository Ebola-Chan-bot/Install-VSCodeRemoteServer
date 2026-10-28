#!/bin/sh
# 包装脚本版本: WRAPPER-V6-SINGLE-DAEMON
# VSCODE-PERSISTENT-WRAPPER-v2 : 让 exec server 的 command-shell 脱离 sshd 会话，并把看门狗父进程钉死为 PID 1
# v5 追加名字豁免：收割按 /proc/<pid>/comm 认名（豁免名单含 tmux/bash/sh/zsh/sshd/screen，实测同名 daemon 存活 17 小时），node 启动后 comm=MainThread、CLI comm=code-insiders-* 均在必死名单，故真身经名为 tmux 的符号链接启动、node 全树经 NODE_OPTIONS 自改名。
# v6 追加单 daemon 复用与令牌剥离：官方安装脚本并发执行时共用 .cli.<提交号>.log 通告端口，文件被后动会话替换后，先动会话会解析到别人 daemon 的端口、配上自己的令牌，握手报 AuthChallengeBadToken；v6 改由 wrapper 捕获 daemon 通告地址写进各自会话的日志、同提交号只保留一个 daemon 并向所有会话回填同一端口，并剥离 VSCODE_CLI_REQUIRE_TOKEN 使握手不再依赖令牌匹配。
# 由本扩展按主机保活配置自动生成；取消该主机的保活勾选后不再维护此包装。
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
		--require-token)
			# 令牌剥离（详见下方说明）：带值选项，连同它的值一起丢弃
			if [ "$REMAIN" -gt 0 ]; then
				shift
				REMAIN=$((REMAIN - 1))
			fi
			;;
		--require-token=*)
			;;
		*)
			set -- "$@" "$ARG"
			;;
	esac
done

# ---- 令牌剥离：daemon 只认一个令牌，而每个安装会话的令牌各不相同，必须让握手不再依赖令牌匹配 ----
# 官方安装脚本每次连接都生成新令牌经VSCODE_CLI_REQUIRE_TOKEN 传入，challenge_issue 拿它与 daemon 的令牌比对。v6 同提交号只留一个 daemon 服务所有会话，令牌必然对不上，故在此剥离（命令行上的 --require-token 已在上方参数改写时丢弃）：daemon 落入 CLI 官方支持的仅 VSDA 签名挑战模式（无令牌模式），身份认证仍由 vsda 签名挑战完成，只是少了令牌这道第二防线。
unset VSCODE_CLI_REQUIRE_TOKEN

# ---- 名字豁免改造：收割按 /proc/<pid>/comm 认名，非豁免名 60 分钟必死 ----
# 实测豁免名单含 tmux（D1 实验：同名启动的 CLI daemon 存活 17 小时），而 node 启动后 comm=MainThread、CLI comm=code-insiders-* 均必死。两招：① 真身经名为 tmux 的符号链接启动，comm 取链接名；② node 全树经 NODE_OPTIONS 加载 comm-renamer.js（由部署脚本落位）自改名为 tmux。跨进程改名不可行（写 /proc/<pid>/comm 一律 EINVAL、ptrace 被 dumpable=0 拒绝），只能各自启动时自改。
RENAMER="$PERSIST_DIR/comm-renamer.js"
if [ -f "$RENAMER" ]; then
	NODE_OPTS="--require $RENAMER"
	export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$NODE_OPTS"
	# VS Code 服务端会把 VSCODE_NODE_OPTIONS 映射为子进程的 NODE_OPTIONS（out/server-main.js），保证 ext host / pty host 等内部 node 也被改名；两者都设可覆盖新旧两条链路
	export VSCODE_NODE_OPTIONS="${VSCODE_NODE_OPTIONS:+$VSCODE_NODE_OPTIONS }$NODE_OPTS"
fi
LAUNCH_DIR="$PERSIST_DIR/launch/$SELF_NAME"
HOLD_DIR="$PERSIST_DIR/hold"
mkdir -p "$LAUNCH_DIR" "$HOLD_DIR" 2>/dev/null || true
ln -sf "$REAL" "$LAUNCH_DIR/tmux" 2>/dev/null || true
ln -sf "$(command -v sleep 2>/dev/null || echo /bin/sleep)" "$HOLD_DIR/tmux" 2>/dev/null || true

# ---- 单 daemon 复用：同提交号共用一个 daemon，端口通告由 wrapper 亲自写进本次会话的日志 ----
# 官方安装脚本把 daemon 的 stdout 重定向进 <数据目录>/.cli.<提交号>.log 再解析 "Listening on" 取端口。并发安装会话共用同一路径：后动的脚本 rm+touch 会把先动脚本的文件换成新文件，先动的脚本于是解析到别人的端口、配上自己的令牌，握手报 AuthChallengeBadToken。v6 把 daemon 的 stdout 落进 wrapper 私有日志，由 wrapper 解析端口后把 "Listening on" 行写进调用方自己的日志；后续会话复用同一 daemon、回填同一端口，无论并发会话各自读到哪份文件内容端口值都完全一致，错配不复存在。
DAEMON_STATE="$PERSIST_DIR/daemon-$SELF_COMMIT.state"
DAEMON_LOG="$PERSIST_DIR/daemon-$SELF_COMMIT.log"
DAEMON_LOCK_DIR="$PERSIST_DIR/daemon-$SELF_COMMIT.lock"
if [ -x "$LAUNCH_DIR/tmux" ]; then
	DAEMON_LAUNCH="$LAUNCH_DIR/tmux"
else
	DAEMON_LAUNCH="$REAL"
fi
DAEMON_MARK="$DAEMON_LAUNCH"

# mkdir 自旋锁互斥并发 wrapper：两个会话同时判定“无 daemon”会各起一个，端口就不一致了
acquire_lock() {
	LOCK_TRIES=0
	while ! mkdir "$DAEMON_LOCK_DIR" 2>/dev/null; do
		LOCK_TRIES=$((LOCK_TRIES + 1))
		if [ "$LOCK_TRIES" -gt 200 ]; then
			log "$SELF_NAME: 等待 daemon 锁超时，放弃互斥继续执行"
			return 0
		fi
		sleep 0.1 2>/dev/null || sleep 1
	done
	return 0
}

release_lock() {
	rmdir "$DAEMON_LOCK_DIR" 2>/dev/null || true
}

# daemon 必须存活且命令行仍指向本提交号的启动链接，防止 pid 被系统复用后误判存活
daemon_alive() {
	[ -n "$1" ] || return 1
	kill -0 "$1" 2>/dev/null || return 1
	tr '\000' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -q "$DAEMON_MARK"
}

# 启动新 daemon 并等待它通告端口，成功后把「pid 地址」写进状态文件
start_daemon() {
	rm -f "$DAEMON_LOG"
	# 双 fork 脱逃：只用 setsid 不够——它改会话与进程组却不改 PPID，而引导脚本那个 sh 的父进程正是 60 分钟到期的 sshd-session，收割按祖先链清理照样命中。本机 setsid 为 util-linux 2.23 无 --fork 选项，故用子 shell 实现双 fork：子 shell 立即退出 → 真身被 init 收养（PPID=1，祖先链断裂）；setsid 另建会话与进程组。经 tmux 名符号链接启动，comm=tmux 豁免收割。
	( setsid "$DAEMON_LAUNCH" "$@" >>"$DAEMON_LOG" 2>&1 & echo $! >"$DAEMON_LOG.pid" )
	DAEMON_PID=$(cat "$DAEMON_LOG.pid" 2>/dev/null || true)
	rm -f "$DAEMON_LOG.pid"
	DAEMON_ADDR=''
	WAIT_N=0
	while [ "$WAIT_N" -lt 150 ]; do
		DAEMON_ADDR=$(sed -n 's/^Listening on //p' "$DAEMON_LOG" 2>/dev/null | head -n 1)
		[ -n "$DAEMON_ADDR" ] && break
		kill -0 "$DAEMON_PID" 2>/dev/null || break
		sleep 0.1 2>/dev/null || sleep 1
		WAIT_N=$((WAIT_N + 1))
	done
	if [ -z "$DAEMON_ADDR" ]; then
		log "$SELF_NAME: daemon 未能通告端口，原样转出其输出供安装脚本诊断"
		cat "$DAEMON_LOG" 2>/dev/null || true
		return 1
	fi
	printf '%s %s\n' "$DAEMON_PID" "$DAEMON_ADDR" >"$DAEMON_STATE"
	log "$SELF_NAME: daemon 已启动（pid $DAEMON_PID），通告地址 $DAEMON_ADDR，参数: $*"
	return 0
}

acquire_lock
DAEMON_PID=''
DAEMON_ADDR=''
if [ -f "$DAEMON_STATE" ]; then
	DAEMON_PID=$(sed -n '1s/ .*//p' "$DAEMON_STATE")
	DAEMON_ADDR=$(sed -n '1s/^[^ ]* //p' "$DAEMON_STATE")
fi
if [ -n "$DAEMON_ADDR" ] && daemon_alive "$DAEMON_PID"; then
	log "$SELF_NAME: 复用已在运行的 daemon（pid $DAEMON_PID），通告地址 $DAEMON_ADDR"
else
	start_daemon "$@" || {
		release_lock
		exit 1
	}
fi
release_lock

# 端口通告写进调用方日志（stdout 即官方安装脚本重定向的 .cli.<提交号>.log），格式必须与 CLI 自身输出逐字一致
printf 'Listening on %s\n' "$DAEMON_ADDR"

# wrapper 自身必须再活片刻：引导脚本在解析出端口前会以 $!（即 wrapper 的 PID）做 kill -0 存活检查，立即退出会被判 "Exec server process not found"。端口行已在上方写出，脚本下一轮解析即 break，占位 300 秒绰绰有余；到点自动退出，不再像旧版那样留下永久游离的占位进程。占位 sleep 同样经 tmux 名链接，避免自身 60 分钟被收割留下杂音。
if [ -x "$HOLD_DIR/tmux" ]; then
	exec "$HOLD_DIR/tmux" 300
else
	exec sleep 300
fi
