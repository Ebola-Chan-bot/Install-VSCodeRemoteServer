# 单会话帧循环（嵌入 Linux 单会话引导体执行）：stdin 上四类帧——__FILE__（<字节数>\n<裸名>\n<裸字节>，落盘 $HOME/）、__CMD__（一行命令静默执行，帧序即"先文件后改名"的原子序，坏包永远不会被就位）、__RUN__（一行命令后台起编排，输出继承会话 stdout 回传，结束回传 __ORCH_EXIT__=N）、__EXIT__（收尾退循环）。
echo __接管会话就绪__
while IFS= read -r FT; do
	case "$FT" in
		__EXIT__)
			break
			;;
		__FILE__)
			IFS= read -r FN
			IFS= read -r FF
			head -c "$FN" > "$HOME/$FF"
			READ_STATUS=$?
			RECEIVED_BYTES=$(wc -c < "$HOME/$FF" | tr -d '[:space:]')
			# 长度不符也可能来自落盘失败；同时回报读取命令退出码，不能只凭本标记归因为传输错位。
			if [ "$READ_STATUS" -ne 0 ] || [ "$RECEIVED_BYTES" != "$FN" ]; then
				echo "__FRAME_TRUNCATED__ $FF expected=$FN received=${RECEIVED_BYTES:-0} read_status=$READ_STATUS"
				exit 1
			fi
			;;
		__CMD__)
			IFS= read -r CC
			sh -c "$CC" >/dev/null 2>&1
			;;
		__RUN__)
			IFS= read -r RR
			( sh -c "$RR" < /dev/null; echo "__ORCH_EXIT__=$?" ) &
			;;
	esac
done
