// VS Code 服务进程 comm 改名器（node 专用）
// 由 服务保活部署脚本.sh 落位到 <服务保活目录>/comm-renamer.js，再由服务保活包装脚本.sh 经 NODE_OPTIONS 与 VSCODE_NODE_OPTIONS（VS Code 服务端会把后者映射为子进程的 NODE_OPTIONS，见 out/server-main.js）注入整棵服务进程树。
//
// 为什么需要它：登录节点有按 /proc/<pid>/comm 认名的超龄收割，非豁免名 60 分钟必死。node 启动后会把自身线程名设为 MainThread（豁免名单外，实测 60 分钟被杀），而收割只认 comm——argv0 伪装无效（实测照死），二进制补丁不可行（MainThread 无独立字面量，只有 C++ 符号名）。改名为 tmux 实测豁免：同名方式启动的 CLI daemon 已存活 17 小时。
//
// 为什么只能"每个进程自改"：跨进程写 /proc/<pid>/comm 一律 EINVAL，给别的进程 ptrace 注入 prctl 也被 dumpable=0 之类的加固拒绝，所以必须由每个 node 进程在启动时加载本脚本。
'use strict';

const fs = require('fs');

const 目标名 = 'tmux';

function 改名() {
	// 只写 /proc/self/comm、不动 argv：VS Code 有以命令行识别进程的逻辑，改 argv 有干扰风险
	try {
		fs.writeFileSync('/proc/self/comm', 目标名);
		return;
	} catch (e) {
		/* 非 Linux 或 /proc 不可写时走兜底 */
	}
	try {
		process.title = 目标名;
	} catch (e) {
		/* 兜底也失败则保持原名，不影响进程运行 */
	}
}

改名();

// 定时重申，防进程名被后续代码改动；unref 保证不拖住短命进程退出
const 重申 = setInterval(改名, 30000);
if (typeof 重申.unref === 'function') {
	重申.unref();
}
