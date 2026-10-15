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
			# 帧完整性校验：实收字节数必须与帧头声明一致，不一致说明发端字节被文本编码改写或传输错位，立即报告并退出，绝不把错位数据当阶段文件送进编排
			if [ "$(wc -c < "$HOME/$FF" | tr -d ' ')" != "$FN" ]; then
				echo "__FRAME_TRUNCATED__ $FF"
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
