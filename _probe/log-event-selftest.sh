#!/bin/bash
# log_event「单一时钟」自检：从真实脚本 remote-install-linux.sh 抽出 log() 与 EVENT_* 初值 + log_event()（测的就是要发布的那份代码，不是复制品），
# 用假时钟驱动两类场景，核对三条性质：
#   ① 一次中断恒为一条消息：每轮 log_event 恰好输出 1 行，且不再有「省略计数」这种会静默吃掉信息的门控；
#   ② 重试就在下个汇报周期：瞬时失败时睡眠 == 当时的周期（不忙轮询）；一次耗时远超周期的尝试之后睡眠回落到 1 秒
#      （长尝试本身算作已消耗一个周期，不在其上再叠固定等待）；
#   ③ 周期无固定上限：连续毫无进展的重试把 EVENT_INTERVAL 一路推过 30（旧的「翻倍 + 封顶 30 秒」已删除；任何形式的固定上限都重新引入了该病根）。进度行改时钟驱动后，间隔再大也不会出现「有字节到却整段无输出」。
# 用法：'C:\Program Files\Git\bin\bash.exe' _probe/log-event-selftest.sh
SRC=$(find . -name 'remote-install-linux.sh' -not -path './.git/*' 2>/dev/null | head -1)
if [ -z "$SRC" ]; then
	echo 'FAIL 找不到 remote-install-linux.sh（请在仓库根目录运行本脚本）' >&2
	exit 1
fi
echo "SRC=$SRC"
TMP=$(mktemp)
OUT=$(mktemp)
FAIL=0

# 抽出真实定义：awk 区间从首行到第一个顶格 } 为止（初值块与函数连成一段抽出，日后改初值不会漏掉）
awk '/^log\(\) \{/,/^\}/' "$SRC" >"$TMP"
awk '/^EVENT_REPORT_AT=0/,/^\}/' "$SRC" >>"$TMP"
for NEED in 'log()' 'log_event()' 'EVENT_SLEEP_NEXT' 'EVENT_INTERVAL' 'EVENT_REPORT_AT'; do
	if ! grep -q "$NEED" "$TMP"; then
		echo "FAIL 抽出的定义里缺少 $NEED（脚本结构已变，请同步更新本自检）" >&2
		exit 1
	fi
done
echo "抽出真实定义 $(wc -l <"$TMP" | tr -d ' ') 行"
# 旧机制必须彻底消失：翻倍、封顶 30、省略计数、门控 early-return
for BAD in 'EVENT_INTERVAL \* 2' 'lt 30' 'EVENT_SILENCED' 'EVENT_WIDEN' 'return 0'; do
	if grep -q "$BAD" "$TMP"; then
		echo "FAIL log_event 里仍残留旧机制 $BAD（与「不要固定 30 秒 / 一次中断一条消息」冲突）" >&2
		exit 1
	fi
done

FAKE_NOW=1000000
date() { echo "$FAKE_NOW"; }
advance() { FAKE_NOW=$((FAKE_NOW + $1)); }
out_lines() { wc -l <"$OUT" | tr -d ' '; }
# $1 = 算术真值（非 0 为真），$2 = 说明
check() {
	if [ "$1" -ne 0 ]; then echo "OK  $2"; else echo "FAIL $2"; FAIL=1; fi
}

# ===== 场景 A：瞬时失败风暴（尝试耗时 0 秒，每轮毫无进展 → 周期逐轮放宽一档）=====
# 轮数取 80：睡眠的递推是 S_n = (n+1) - S_{n-1}（≈ n/2），要把「睡眠 >30」也验到需要约 62 轮以上，故取 80（假时钟瞬间跑完）
ROUNDS=80
echo ''
echo "===== 场景 A：瞬时失败风暴 $ROUNDS 轮（尝试 0 秒，每轮 EVENT_INTERVAL++） ====="
. "$TMP"
: >"$OUT"
PRINTED=0
ALIGN_BAD=0
GAP_BAD=0
for i in $(seq 1 $ROUNDS); do
	BEFORE=$(out_lines)
	# 本轮在上次汇报之后已耗掉的秒数（与 Windows 侧 catch 里的 ($此刻 - $上次汇报时刻) 同义）
	if [ "$EVENT_REPORT_AT" -eq 0 ]; then
		ELAPSED=999999
	else
		ELAPSED=$((FAKE_NOW - EVENT_REPORT_AT))
	fi
	ROUND_START=$FAKE_NOW
	# 调用方规则：本轮毫无进展 → 先放宽周期，再报事件（与 Windows 侧 catch 里的 周期++ 同序，均不设上限）
	EVENT_INTERVAL=$((EVENT_INTERVAL + 1))
	log_event "第 $i 次下载失败（2 个源均未取到，残留已清理）" >>"$OUT"
	GOT=$(( $(out_lines) - BEFORE ))
	PRINTED=$((PRINTED + GOT))
	# 对齐断言：睡眠 == 周期 − 本轮已耗（下限 1 秒）
	WANT=$((EVENT_INTERVAL - ELAPSED))
	if [ "$WANT" -lt 1 ]; then WANT=1; fi
	if [ "$EVENT_SLEEP_NEXT" -ne "$WANT" ]; then ALIGN_BAD=$((ALIGN_BAD + 1)); fi
	# 间隔断言：模拟时钟前进量 == 声明的等待
	advance "$EVENT_SLEEP_NEXT"
	GAP=$((FAKE_NOW - ROUND_START))
	if [ "$GAP" -ne "$EVENT_SLEEP_NEXT" ]; then GAP_BAD=$((GAP_BAD + 1)); fi
	if [ "$i" -le 6 ] || [ "$i" -ge $((ROUNDS - 1)) ]; then
		echo "  第 $i 轮: 放行 $GOT 行, 睡眠 ${EVENT_SLEEP_NEXT}s, 周期 $EVENT_INTERVAL（累计模拟 $((FAKE_NOW - 1000000))s）"
	fi
done
check $((PRINTED == ROUNDS)) "每轮恰好一条消息：放行 $PRINTED == 轮数 $ROUNDS（一次中断不再产出两条）"
check $((ALIGN_BAD == 0)) "睡眠秒数 == 周期 − 本轮已耗（对齐偏差 $ALIGN_BAD 轮）"
check $((GAP_BAD == 0)) "消息间隔 == 声明的等待秒数（偏差 $GAP_BAD 轮）"
check $((EVENT_INTERVAL > 30)) "周期无固定上限：$ROUNDS 轮毫无进展后 EVENT_INTERVAL=$EVENT_INTERVAL > 30"
check $((EVENT_SLEEP_NEXT > 30)) "重试等待跟随周期：末轮睡眠 ${EVENT_SLEEP_NEXT}s > 30（既不再封顶 30 秒，也没被任何上限压住）"
if grep -q '另有 .* 次同类中断已省略' "$OUT"; then check 0 '不应再出现省略计数'; else check 1 '不再出现省略计数（每轮一条消息，无需省略）'; fi
if grep -q '，下个汇报周期（' "$OUT"; then
	check 1 '事件行自带「下个汇报周期（N 秒后）重试」措辞'
else
	check 0 '事件行应自带「下个汇报周期」措辞（实测缺失）'
fi
echo "  末条事件行: $(tail -1 "$OUT")"

# 瞬时失败（elapsed=0）：睡眠必须正好等于当时的周期
. "$TMP"
: >"$OUT"
EVENT_INTERVAL=5
EVENT_REPORT_AT=$FAKE_NOW
log_event '第 1 次下载失败（瞬时失败）' >>"$OUT"
check $((EVENT_SLEEP_NEXT == EVENT_INTERVAL)) "瞬时失败：睡眠 ${EVENT_SLEEP_NEXT}s == 周期 ${EVENT_INTERVAL}s（下个汇报周期才重试，不忙轮询）"

# ===== 场景 B：长耗时尝试（每轮尝试 60 秒，周期固定 17 秒且不放宽）=====
echo ''
echo '===== 场景 B：长耗时尝试（每轮尝试 60 秒，周期 17 秒） ====='
. "$TMP"
: >"$OUT"
EVENT_INTERVAL=17
EVENT_REPORT_AT=$FAKE_NOW
LONG_MAX_SLEEP=0
for i in 1 2 3; do
	advance 60
	BEFORE=$(out_lines)
	log_event "第 $i 次下载失败（长耗时停等 60 秒后失败）" >>"$OUT"
	GOT=$(( $(out_lines) - BEFORE ))
	check $((GOT == 1)) "长耗时第 $i 轮放行 1 行（实测 $GOT）"
	echo "  第 $i 轮: 放行 $GOT 行, 睡眠 ${EVENT_SLEEP_NEXT}s（周期 $EVENT_INTERVAL，尝试耗时 60s）"
	advance "$EVENT_SLEEP_NEXT"
	if [ "$EVENT_SLEEP_NEXT" -gt "$LONG_MAX_SLEEP" ]; then LONG_MAX_SLEEP=$EVENT_SLEEP_NEXT; fi
done
check $((LONG_MAX_SLEEP == 1)) "长耗时尝试后只再等 1 秒（实测最大 ${LONG_MAX_SLEEP}s）= 重试对齐下个汇报周期，没在 60 秒之上再叠固定等待"

# ===== 场景 C：调用点一致性（三个下载循环都必须按 EVENT_SLEEP_NEXT 睡、且只在无进展时放宽周期）=====
echo ''
echo '===== 场景 C：调用点结构核对 ====='
SLEEP_OK=$(grep -c 'sleep "$EVENT_SLEEP_NEXT"' "$SRC")
check $((SLEEP_OK == 3)) "三个下载循环都按 EVENT_SLEEP_NEXT 睡（实测 $SLEEP_OK 处，期望 3）"
WIDEN_OK=$(grep -c 'EVENT_INTERVAL=$((EVENT_INTERVAL + 1))' "$SRC")
check $((WIDEN_OK == 3)) "三处「本轮毫无进展才放宽周期」（实测 $WIDEN_OK 处，期望 3）"
# 封顶守卫要打到真实源码（上面的 BAD 循环只扫抽出的 log/log_event 定义，抓不到调用点）：任何形式的固定上限都是重新引入「固定周期必刷一行」那个病根
CAP_OK=$(grep -c -- '-lt 10' "$SRC")
check $((CAP_OK == 0)) "周期放宽无封顶：生产源码里没有给 EVENT_INTERVAL / REPORT_PERIOD 加 -lt 10 类上限（实测命中 $CAP_OK 处）"
OLD_SLEEP=$(grep -c 'sleep "$WAIT_SECONDS"\|sleep "$CLI_ATTEMPT"\|sleep "$WAIT_SEC"' "$SRC")
check $((OLD_SLEEP == 0)) "已无写死秒数的旧 sleep（实测 $OLD_SLEEP 处，期望 0）"
EVENT_CALLS=$(grep -c 'log_event "' "$SRC")
check $((EVENT_CALLS == 3)) "每轮只有一处 event 调用点（实测 $EVENT_CALLS 处，期望 3）= 一次中断一条消息"

rm -f "$TMP" "$OUT"
echo ''
echo "断言失败数: $FAIL"
exit $FAIL
