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

# 后台历史清理的报告文件与完成标记：清理改由后台子进程执行，它的输出落进报告文件，下一次连接开头回放（同 Windows 通用版的做法）
GC_REPORT="$DATA_DIR/.vsi-gc-report.log"
GC_DONE_MARK='__清理完成__'

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

# 日志输出辅助函数。**不内嵌时钟**：本脚本的输出经 SSH 转发后会由外层（VS Code preconnect 日志/本地转发层）按**本地时钟**标注，而远端钟表与本机可以相差几分钟（用 _probe/远端时钟偏差.ps1 量：同样是本次测试用的主机，A 机只差约 0.5 秒、B 机差约 225 秒，且每台主机各有各的值、还会漂），两套时钟混排会让人完全无法排序时间线——2026-10-24 就据此把「CLI 已获胜后约 21 秒取消本地供给」误读成了 4 分钟。与 Windows 侧同一纪律（见 remote-install-common.ps1 中断行处注释）
log() {
	echo "$*"
}

# 事件行输出（下载失败/重试等中断提示）：与 Windows 侧同一个「单一时钟」规则——汇报周期既是打印节奏也是重试节奏。一次中断恒为一条消息（每轮只调一次，各源的细节由调用方并进同一条正文，不另起行）；异常先记录，EVENT_SLEEP_NEXT 到下个汇报点的剩余等待（下限 1 秒），等待结束才打印并立即重试，不在异常瞬间抢先打印，也不在汇报后再叠一段固定等待；只由调用方在「本轮毫无进展」时 EVENT_INTERVAL 放宽一档，放宽不设上限（中途越糟间隔越长；仍禁止旧的「翻倍 + 封顶 30 秒」与任何形式的固定上限）。心跳行（race_artifact）与时钟无关地按周期报已传字节数，故源端爬行期报 0 字节也不会死寂。
# POSIX sh 无局部变量，门控状态一律用 EVENT_ 前缀的独特全局名，避免与调用方变量互相覆盖（教训：循环变量曾覆盖同名配置变量）。
EVENT_REPORT_AT=0
EVENT_INTERVAL=1
EVENT_SLEEP_NEXT=1
log_event() {
	EVENT_NOW=$(date +%s)
	EVENT_ELAPSED=$EVENT_NOW
	if [ "$EVENT_REPORT_AT" -gt 0 ]; then
		EVENT_ELAPSED=$((EVENT_NOW - EVENT_REPORT_AT))
	fi
	# 本轮在上次汇报之后已耗掉的时间算进周期，故差值即「到下个汇报点的剩余等待」
	EVENT_SLEEP_NEXT=$((EVENT_INTERVAL - EVENT_ELAPSED))
	if [ "$EVENT_SLEEP_NEXT" -lt 1 ]; then
		EVENT_SLEEP_NEXT=1
	fi
	# 原因可能自带尾句号，直接拼分隔符会出现「…字节。，」这种错标点，先剥尾部标点
	EVENT_REASON=$(printf '%s' "$1" | sed 's/[。，、；！;.!]*$//')
	# 异常先记录，等到下个汇报周期再打印；打印后立即续传，不在汇报后再叠等待。
	sleep "$EVENT_SLEEP_NEXT"
	log "$EVENT_REASON（上个汇报周期内发生）。本次汇报即续传重试"
	EVENT_REPORT_AT=$(date +%s)
}

# 竞速暂存目录清理（并发安全）：绝不 rm -rf 整目录——另一条并发连接（同主机同提交号，staging 名相同）可能正在传 <包名>.uploading，或在写 <包名>.downloading-<PID>（本端自下载的私有在途名），整删会让它的改名步骤报「在途文件不在」而失去供给。只清非在途项（残留完成/取消标记会让本轮误判胜负，完整包本轮要重新竞速），在途文件超过 6 小时未动（死连接遗留）才顺手清掉防堆积。
cleanup_staging() {
	if [ -z "$STAGING" ]; then
		return 0
	fi
	if [ ! -d "$STAGING" ]; then
		mkdir -p "$STAGING" 2>/dev/null || true
		return 0
	fi
	for F in "$STAGING"/* "$STAGING"/.[!.]*; do
		[ -e "$F" ] || continue
		case "$F" in
			*.uploading)
				continue
				;;
			*.downloading-*)
				continue
				;;
		esac
		rm -rf "$F" 2>/dev/null || true
	done
	if command -v find >/dev/null 2>&1; then
		find "$STAGING" -name '*.uploading' -mmin +360 -exec rm -f '{}' ';' 2>/dev/null || true
		find "$STAGING" -name '*.downloading-*' -mmin +360 -exec rm -f '{}' ';' 2>/dev/null || true
	fi
}

# ===== 下载原语（sh 逐行解释执行，函数必须定义在所有调用点之前：install_cli 在下方即会调用）=====
download_file() {
	url="$1"
	output="$2"
	rm -f "$output.headers" "$output.length"
	if [ "$DOWNLOADER" = 'curl' ]; then
		# curl 默认往 stderr 打英文进度条（回车刷屏文案），会污染输出流；-s 静音进度条、-S 仍显示错误；响应头中的长度供共享汇报器显示百分比。
		curl -fsSL --connect-timeout 30 -D "$output.headers" -o "$output" "$url"
		DL_RC=$?
		if [ -f "$output.headers" ]; then
			DL_LENGTH=$(awk 'BEGIN { IGNORECASE=1 } /^Content-Length:/ { gsub("\\r", "", $2); value=$2 } END { print value }' "$output.headers")
			case "$DL_LENGTH" in ''|*[!0-9]*) ;; *) echo "$DL_LENGTH" > "$output.length" ;; esac
		fi
		return "$DL_RC"
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

# ===== 下载与竞速原语（sh 逐行解释执行，函数必须定义在所有调用点之前）=====

# 远程自下载 server 压缩包（无限重试 + 双备用地址）：$1=包路径 $2=完成标记；竞速模式下后台拉起，决出后被整体终止，故无需取消检查
run_remote_download() {
	PKG_OUT="$1"
	DONE_MARK="$2"
	# 私有在途名（<成品名>.downloading-<PID>）：与 Windows 侧、本地供给同一纪律。此前所有会话都直接往同一个成品名写，Remote-SSH超时重试造成两条会话重叠时两个 curl 必抢同一文件：字节交织后 gzip -t 不过，两边各自 rm -f 重来 → 永不收敛的互相毁包。download_file不带 Range（curl -o / wget -O 总从头写），在途文件无续传价值，此处只做会话隔离 + 完成才发布
	IN_FLIGHT="${PKG_OUT}.downloading-$$"
	CLI_ATTEMPT=0
	SRC_TOTAL=2
	# 源清单只公布一次：无限重试下每轮都重刷整条 URL 会洩掉日志；每源一行的「开始下载」同样只在首轮报，其后由受节流的事件行带回次数与源序号（序号回指本清单）
	# 端标注 [远程自下载-服务端] 与本地侧 [本地供给-服务端] 对称（当前调用方把本函数输出静音，标注是为了日后不再静音时依旧分得清两端）
	log "[远程自下载-服务端] 下载源（共 $SRC_TOTAL 个，按序轮试）：1) $URL_PRIMARY  2) $URL_FALLBACK"
	# 无限重试，重试时刻对齐到下个汇报周期（见 log_event），不再写死递增秒数
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		SRC_IDX=0
		ROUND_GOT=0
		ROUND_NOTE=''
		for URL in "$URL_PRIMARY" "$URL_FALLBACK"; do
			SRC_IDX=$((SRC_IDX + 1))
			if [ "$CLI_ATTEMPT" -eq 1 ]; then
				log "[远程自下载-服务端] 开始下载（源 $SRC_IDX/$SRC_TOTAL）"
			fi
			if download_file "$URL" "$IN_FLIGHT" && [ -s "$IN_FLIGHT" ]; then
				ROUND_GOT=1
				# gzip 完整性校验：流式下载读到底不等于传完整，截断包解压只会报晦涩错误，坏包弃用换源重下
				if gzip -t "$IN_FLIGHT" 2>/dev/null; then
					# 发布：先改名到成品名、再写完成标记 —— 顺序不可颠倒，否则会短暂出现「标记在、包不完整」的窗口骗过竞速判定。成品已被并发会话发布（同提交号内容等价）则丢自己的副本；连改名也做不成就本端退出，交回本地供给接手
					if [ -s "$PKG_OUT" ] && gzip -t "$PKG_OUT" 2>/dev/null; then
						rm -f "$IN_FLIGHT"
						log "[远程自下载-服务端] 并发会话已先发布成品，改用已发布的包。"
					elif mv -f "$IN_FLIGHT" "$PKG_OUT" 2>/dev/null; then
						log "[远程自下载-服务端] 下载完成，已改名发布成品（$(wc -c < "$PKG_OUT" 2>/dev/null | tr -d ' ') 字节）。"
					else
						rm -f "$IN_FLIGHT"
						log "[远程自下载-服务端] 成品名改写失败（被并发会话占用），本端退出下载，由本地供给接手。"
						return 1
					fi
					touch "$DONE_MARK"
					return 0
				fi
				# 截断原因并进本轮唯一一条事件行，不另起一行（一次失败多条消息就是冗余汇报点）
				ROUND_NOTE="${ROUND_NOTE}源 $SRC_IDX 的包完整性校验未通过已弃用；"
			fi
			rm -f "$IN_FLIGHT"
		done
		# 本轮毫无进展（一个字节都没落地）才放宽周期（无上限）；拿到过字节时周期不动，失败不额外拖慢恢复
		if [ "$ROUND_GOT" -eq 0 ]; then
			EVENT_INTERVAL=$((EVENT_INTERVAL + 1))
		fi
		log_event "[远程自下载-服务端] 第 $CLI_ATTEMPT 次下载失败（$SRC_TOTAL 个源均未取到，${ROUND_NOTE}残留已清理）"
	done
}

# 远程自下载 CLI 压缩包（竞速模式下后台拉起）：$1=包路径 $2=完成标记；同样无限重试，决出后被整体终止
run_remote_cli_download() {
	PKG_OUT="$1"
	DONE_MARK="$2"
	IN_FLIGHT="${PKG_OUT}.downloading-$$"
	CLI_ATTEMPT=0
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		# CLI 地址只在首次尝试时公布，重试轮不再回显（脚本开头已另有一行 CLI 下载地址）
		if [ "$CLI_ATTEMPT" -eq 1 ]; then
			log "[远程自下载-CLI] 开始下载远程 CLI: $CLI_URL"
		fi
		ROUND_GOT=0
		ROUND_NOTE=''
		if download_file "$CLI_URL" "$IN_FLIGHT" && [ -s "$IN_FLIGHT" ]; then
			ROUND_GOT=1
			if gzip -t "$IN_FLIGHT" 2>/dev/null; then
				# 发布：先改名到成品名、再写完成标记（与 run_remote_download 同纪律）
				if [ -s "$PKG_OUT" ] && gzip -t "$PKG_OUT" 2>/dev/null; then
					rm -f "$IN_FLIGHT"
					log "[远程自下载-CLI] 并发会话已先发布成品，改用已发布的包。"
				elif mv -f "$IN_FLIGHT" "$PKG_OUT" 2>/dev/null; then
					log "[远程自下载-CLI] 下载完成，已改名发布成品（$(wc -c < "$PKG_OUT" 2>/dev/null | tr -d ' ') 字节）。"
				else
					rm -f "$IN_FLIGHT"
					log "[远程自下载-CLI] 成品名改写失败（被并发会话占用），本端退出下载，由本地供给接手。"
					return 1
				fi
				touch "$DONE_MARK"
				return 0
			fi
			ROUND_NOTE='包完整性校验未通过已弃用，'
		fi
		rm -f "$IN_FLIGHT"
		# 本轮毫无进展才放宽周期（与 run_remote_download 同规则，无上限）
		if [ "$ROUND_GOT" -eq 0 ]; then
			EVENT_INTERVAL=$((EVENT_INTERVAL + 1))
		fi
		# 失败与重试合并为一条事件行（旧写法每轮刷「清理残留」+「等待重试」+「第 N 次尝试」共 3 行）
		log_event "[远程自下载-CLI] 第 $CLI_ATTEMPT 次 CLI 下载失败（${ROUND_NOTE}残留已清理）"
	done
}

# 启动单个产物竞速；统一协调器随后同时监控 CLI 与服务端。启动结果经 RACE_START_* 返回。
start_race_artifact() {
	RACE_START_READY=0
	RACE_START_PID=''
	RACE_START_PKG=''
	# 清理本端上一轮残留：只删标记（残留标记 = 假获胜）与不完整的成品；本地包与本地标记由本地供给任务管理，不在此处删（可能已先于本脚本完成）
	rm -f "$3" "$6"
	# 成品已完整则直接获胜（存在即视为完成）：staging 按提交号命名，同名即同版本，而成品如今只由「校验通过后才改名发布」产生。实测 190MB 包在慢网下两边各下一遍纯属浪费带宽；旧版直接写成品名留下的截断半成品会在这里被 gzip -t 判为不完整而重下
	if [ -s "$2" ] && gzip -t "$2" 2>/dev/null; then
		touch "$3"
		touch "$6"
		RACE_START_READY=1
		RACE_START_PKG="$2"
		log "[远程自下载-$1] 远端已有完整自下载成品（$(wc -c < "$2" 2>/dev/null | tr -d ' ') 字节），直接判远程自下载获胜，跳过重复下载。"
		# 与下面正常决出路径同一事件行格式：主模块回调按「竞速决出：X 由远程自下载获胜」按产物粒度击杀对应本地供给；缺这行时本路径直接 return，本地供给会把已无用的包白下完
		log "竞速决出：$1 由远程自下载获胜（用包 $(basename "$2")）。"
		return 0
	fi
	rm -f "$2"
	log "$1 竞速：远程自下载与本地下载+上传并行，先完成者用于安装。"
	DL_PID=''
	if [ -n "$7" ]; then
		"$7" "$2" "$3" >/dev/null 2>&1 &
		DL_PID=$!
	else
		log "[远程自下载-$1] 本端缺少 curl/wget 不参与下载，只等本地供给。"
	fi

	RACE_START_PID="$DL_PID"
}

# 读取一个产物的当前在途字节与已知总长度，供统一汇报器使用。
race_measure() {
	RACE_CUR_SIZE=0
	RACE_CUR_TOTAL=0
	for RACE_MF in "$1" "$1".downloading-*; do
		[ -e "$RACE_MF" ] || continue
		RACE_MS=$(wc -c < "$RACE_MF" 2>/dev/null | tr -d ' ')
		case "$RACE_MS" in ''|*[!0-9]*) RACE_MS=0 ;; esac
		if [ "$RACE_MS" -gt "$RACE_CUR_SIZE" ]; then RACE_CUR_SIZE=$RACE_MS; fi
		if [ -f "$RACE_MF.length" ]; then
			RACE_MT=$(cat "$RACE_MF.length" 2>/dev/null || echo 0)
			case "$RACE_MT" in ''|*[!0-9]*) RACE_MT=0 ;; esac
			if [ "$RACE_MT" -gt 0 ]; then RACE_CUR_TOTAL=$RACE_MT; fi
		fi
	done
}

# CLI 与服务端同时竞速；这里只发送快照，preconnect 的单一汇报器按活跃产物投票，已完成产物不再发送也不再投票。
race_all_artifacts() {
	RACE_CLI_ACTIVE=0
	RACE_SERVER_ACTIVE=0
	RACE_CLI_PID=''
	RACE_SERVER_PID=''
	if [ "$NEED_CLI" = '1' ]; then
		start_race_artifact 'CLI' "$STAGING/REMOTE_CLI.tar.gz" "$STAGING/REMOTE_CLI_DONE" "$STAGING/LOCAL_CLI.tar.gz" "$STAGING/LOCAL_CLI_DONE.$ARCH" "$STAGING/LOCAL_CLI_CANCEL" "$RACE_CLI_DL_FN"
		RACE_CLI_PID=$RACE_START_PID
		RACE_CLI_ACTIVE=1
		if [ "$RACE_START_READY" = '1' ]; then RACE_CLI_ACTIVE=0; CLI_WINNER_PKG=$RACE_START_PKG; fi
	fi
	if [ "$NEED_SERVER" = '1' ]; then
		start_race_artifact '服务端' "$STAGING/REMOTE.tar.gz" "$STAGING/REMOTE_DONE" "$STAGING/LOCAL.tar.gz" "$STAGING/LOCAL_DONE.$ARCH" "$STAGING/LOCAL_CANCEL" "$RACE_SERVER_DL_FN"
		RACE_SERVER_PID=$RACE_START_PID
		RACE_SERVER_ACTIVE=1
		if [ "$RACE_START_READY" = '1' ]; then RACE_SERVER_ACTIVE=0; SERVER_WINNER_PKG=$RACE_START_PKG; fi
	fi
	while [ "$RACE_CLI_ACTIVE" = '1' ] || [ "$RACE_SERVER_ACTIVE" = '1' ]; do
		if [ "$RACE_CLI_ACTIVE" = '1' ]; then
			RACE_WINNER=''
			if [ -f "$STAGING/REMOTE_CLI_DONE" ]; then RACE_WINNER='远程自下载'; CLI_WINNER_PKG="$STAGING/REMOTE_CLI.tar.gz";
			elif [ -f "$STAGING/LOCAL_CLI_DONE.$ARCH" ]; then RACE_WINNER='本地供给'; CLI_WINNER_PKG="$STAGING/LOCAL_CLI.tar.gz"; fi
			if [ -n "$RACE_WINNER" ]; then
				touch "$STAGING/LOCAL_CLI_CANCEL"
				if [ -n "$RACE_CLI_PID" ]; then
					if command -v pkill >/dev/null 2>&1; then pkill -P "$RACE_CLI_PID" 2>/dev/null || true; fi
					kill "$RACE_CLI_PID" 2>/dev/null || true
					wait "$RACE_CLI_PID" 2>/dev/null || true
				fi
				log "竞速决出：CLI 由${RACE_WINNER}获胜（用包 $(basename "$CLI_WINNER_PKG")）。"
				RACE_CLI_ACTIVE=0
			fi
		fi
		if [ "$RACE_SERVER_ACTIVE" = '1' ]; then
			RACE_WINNER=''
			if [ -f "$STAGING/REMOTE_DONE" ]; then RACE_WINNER='远程自下载'; SERVER_WINNER_PKG="$STAGING/REMOTE.tar.gz";
			elif [ -f "$STAGING/LOCAL_DONE.$ARCH" ]; then RACE_WINNER='本地供给'; SERVER_WINNER_PKG="$STAGING/LOCAL.tar.gz"; fi
			if [ -n "$RACE_WINNER" ]; then
				touch "$STAGING/LOCAL_CANCEL"
				if [ -n "$RACE_SERVER_PID" ]; then
					if command -v pkill >/dev/null 2>&1; then pkill -P "$RACE_SERVER_PID" 2>/dev/null || true; fi
					kill "$RACE_SERVER_PID" 2>/dev/null || true
					wait "$RACE_SERVER_PID" 2>/dev/null || true
				fi
				log "竞速决出：服务端由${RACE_WINNER}获胜（用包 $(basename "$SERVER_WINNER_PKG")）。"
				RACE_SERVER_ACTIVE=0
			fi
		fi
		if [ "$RACE_CLI_ACTIVE" != '1' ] && [ "$RACE_SERVER_ACTIVE" != '1' ]; then break; fi
		sleep 1
		if [ "$RACE_CLI_ACTIVE" = '1' ]; then
			race_measure "$STAGING/REMOTE_CLI.tar.gz"
			printf '__VSI_SNAPSHOT__{"端":"远程","产物":"CLI","已下载":%s,"总长度":%s}\n' "$RACE_CUR_SIZE" "$RACE_CUR_TOTAL"
		fi
		if [ "$RACE_SERVER_ACTIVE" = '1' ]; then
			race_measure "$STAGING/REMOTE.tar.gz"
			printf '__VSI_SNAPSHOT__{"端":"远程","产物":"服务端","已下载":%s,"总长度":%s}\n' "$RACE_CUR_SIZE" "$RACE_CUR_TOTAL"
		fi
	done
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

	# 私有在途名：与竞速侧同一纪律，避免两条并发会话抢同一个固定名的 CLI 包（unpack_cli_package 会把它删掉，不残留）
	CLI_TAR="$DATA_DIR/vscode-cli-$COMMIT.tar.gz.downloading-$$"
	# 顺手扫旧版固定名留下的孤儿包（只清 6 小时未动的；新在途名不匹配该过滤）
	if command -v find >/dev/null 2>&1; then
		find "$DATA_DIR" -maxdepth 1 -name 'vscode-cli-*.tar.gz' -not -name '*.downloading-*' -mmin +360 -exec rm -f '{}' ';' 2>/dev/null || true
	fi
	CLI_ATTEMPT=0
	while true; do
		CLI_ATTEMPT=$((CLI_ATTEMPT + 1))
		# 每轮重试前复查：官方引导可能已并行把 CLI 装好，此时安装实际已完成，直接收尾退出，不再无谓下载重试
		if [ -f "$CLI_ON_DISK" ]; then
			log "CLI 已就位（并行安装完成），跳过安装: $CLI_ON_DISK"
			return 0
		fi
		# CLI 地址只在首次尝试时公布，重试轮不再回显（脚本开头已有一行 CLI 下载地址可回指）
		if [ "$CLI_ATTEMPT" -eq 1 ]; then
			log "[远程自下载-CLI] 开始下载远程 CLI: $CLI_URL"
		fi
		ROUND_GOT=0
		if download_file "$CLI_URL" "$CLI_TAR" && [ -s "$CLI_TAR" ]; then
			ROUND_GOT=1
			unpack_cli_package "$CLI_TAR" && return 0
		fi
		rm -f "$CLI_TAR"
		# 前台补装同样是单一时钟：本轮毫无进展才放宽周期（无上限），重试等到下个汇报周期
		if [ "$ROUND_GOT" -eq 0 ]; then
			EVENT_INTERVAL=$((EVENT_INTERVAL + 1))
		fi
		log_event "[远程自下载-CLI] 第 $CLI_ATTEMPT 次 CLI 补装下载失败（残留已清理）"
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

# ===== 历史版本回收：后台子进程执行，不占用本次连接的主流程 =====
# 删除每个约 250MB 的旧版本目录实测要数秒一个，十几个版本能把连接前流程占住近一分钟，而历史清理与本次安装毫无先后依赖，故改后台执行，明细在下一次连接开头回放。
# 报告含完成标记 = 上一轮已结束，回放后删除；报告新鲜且无标记 = 上一轮仍在跑，本轮不重复启动（避免两个进程同写一份报告、互相抢删）；报告超龄仍无标记 = 上一轮进程已随断线消失，删掉重开。
# 代价：不再保证“清理先于下载腾出磁盘”，磁盘吃紧的主机上删除与下载会并发。
if [ -f "$GC_REPORT" ]; then
	if grep -qs "$GC_DONE_MARK" "$GC_REPORT"; then
		while IFS= read -r GC_LINE; do
			if [ -n "$GC_LINE" ] && [ "$GC_LINE" != "$GC_DONE_MARK" ]; then
				log "[上一轮后台历史清理] $GC_LINE"
			fi
		done < "$GC_REPORT"
		rm -f "$GC_REPORT"
	else
		GC_STALE=1
		# find 不支持 -mmin 的主机取不到年龄信息，一律按超龄处理：宁可重开一轮，也不要永远卡在“仍在进行”而不再清理
		if find "$GC_REPORT" -mmin -30 2>/dev/null | grep -q .; then
			GC_STALE=0
		fi
		if [ "$GC_STALE" = '1' ]; then
			log '后台历史清理报告超过 30 分钟仍未完成（进程可能已随断线消失），本轮重新启动。'
			rm -f "$GC_REPORT"
		else
			log '上一轮后台历史清理仍在进行，本轮不重复启动。'
		fi
	fi
fi
if [ ! -f "$GC_REPORT" ]; then
	# 报告落在数据目录下，首次安装时该目录还不存在，重定向会静默失败导致清理永不执行，先建好
	mkdir -p "$DATA_DIR" 2>/dev/null || true
	# 双层子 shell + 后台：外层子 shell 立即退出让后台作业 PPID 归 1（脱离按祖先链收割的会话策略，同保活方案的双 fork 思路）；stdout/stderr 落报告文件、stdin 接 /dev/null，不再持有本会话管道，SSH 不会为它挂住
	( { cleanup_old_versions || true; echo "$GC_DONE_MARK"; } > "$GC_REPORT" 2>&1 < /dev/null & )
	log '历史版本清理已在远端后台启动（不占用本次安装流程），清理明细在下一次连接开头回放。'
fi

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
	# ===== 竞速模式：CLI 与服务端同时开始，本地与远程快照统一交给 preconnect 的单一汇报器 =====
	# 单边断网时由另一边补上：远端连不上下载服务器就等本地供给，本地下载失败就等远程自下载
	mkdir -p "$STAGING"
	# 本地组合协调器与远端同时收到全部待装产物，两个产物独立判胜、互不等候。
	RACE_PENDING=''
	if [ "$NEED_CLI" = '1' ]; then
		RACE_PENDING='CLI'
	fi
	if [ "$NEED_SERVER" = '1' ]; then
		RACE_PENDING="${RACE_PENDING}${RACE_PENDING:+ }服务端"
	fi
	if [ -n "$RACE_PENDING" ]; then
		echo "__接管预备完成__$RACE_PENDING"
	fi
	RACE_CLI_DL_FN=''
	RACE_SERVER_DL_FN=''
	if [ -n "$DOWNLOADER" ]; then
		RACE_CLI_DL_FN='run_remote_cli_download'
		RACE_SERVER_DL_FN='run_remote_download'
	fi
	race_all_artifacts
	if [ "$NEED_CLI" = '1' ] || [ "$NEED_SERVER" = '1' ]; then
		# 至少一个产物竞速决出：该行触发主流程立即击杀本地供给进程树（零轮询即时取消）
		echo '竞速获胜：全部产物已就位，开始安装。'
	else
		# CLI 与服务端均已就位时根本没发生竞速与下载，如实说明，避免"竞速获胜/下载地址"被误读成每次连接都在重新下载
		echo 'CLI 与服务端均已就位：本轮零下载，跳过竞速，直接进入安装检查。'
	fi
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

# 竞速暂存目录用完即清（双保险：本地模块收尾时还会再清一次）；不碰并发连接正在传的在途文件，详见 cleanup_staging
if [ -n "$STAGING" ]; then
	cleanup_staging
fi

echo '安装完成，当前目录内容如下。'
ls -la "$INSTALL_DIR"
