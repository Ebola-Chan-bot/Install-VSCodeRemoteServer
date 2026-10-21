// 终端通道救援：检测并自动修复「窗口 renderer ↔ pty host 终端通道死亡」——Remote-SSH 连接命令经窗口终端下发，通道死时命令根本没被执行（本地无 ssh 进程、远端 sshd 无认证记录、连接终端零输出、32 秒硬超时），reload/重装扩展/清远端均无效，病灶在窗口进程内部（实测：VS Code 更新换代期 pty host 懒启动拖约 99 秒，期间绑定终端消息端口的窗口把坏状态带进后续所有连接尝试；同期新窗口对同一主机秒连成功——pty host 进程本身健康，坏的是特定窗口的绑定）。
//
// 救援阶梯（全自动，零手动步骤）：
//   L0 探针    createTerminal 瞬态终端限时竞速 processId（选项复刻 Remote-SSH 的连接终端，走同一条本地通道）→ 三态判读
//   L1 就地修复 CDP 断点交接进本窗口 renderer 的 DI 容器：先只读取证（backend 注册表、connectionState、直连端口 pending 是否落定、
//              localPtyService 形态、remoteAgent 连接态），再对症就地修（清空永久悬挂的直连 pending 并重新取端口——与官方
//              onPtyHostRestart 的回线动作同款，但不重启 pty 宿主；懒 localPtyService 强制实例化）→ 复探
//   L2 重锤    workbench.action.terminal.restartPtyHost（就地重连也拉不回时才用；backend 的 onPtyHostRestart 会清代理与 pending 并重取端口，
//              对端口路径彻底坏死仍有救；代价是本机 pty 宿主重启、各窗口本地终端由 VS Code 自动重连）→ 复探
//   L3 逃逸    自动在新窗口重开当前窗口指向的远程（实测 100% 有效：新窗口 = 全新的 pty 宿主端口绑定），原窗口通知说明、按主机冷却防窗口风暴
//
// 三段注入 renderer 的载荷脚本已独立成文件（`renderer-scripts/`，见下方 取渲染器脚本），不再内嵌字符串。
// CDP 手法与断点护栏与本机「Copilot Chat 注入器」扩展同源（minWebSocket 亦移植自它）：条件断点（页内求值，未捕获零暂停）、暂停收集器先于布点订阅（防丢帧冻结页面）、帧内只做同步钥匙交接（捕获+resume 在 paused 处理器内完成，绝不在主流程 await 输入回执——输入回执会被断点暂停卡死，探测阶段实测的死锁教训）、finally 必摘断点+resume+关调试器（resume 失败则断开 WS，调试端断开 V8 自动放行）。载荷里拿到的服务引用全是 DI bound 代理（只暴露接口方法），故 _getOrCreateServiceInstance 这类深度操作只在根容器（InstantiationService 真身）上做。
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const cdp = require('./cdp.js');

const 钥匙前缀 = '__vsiTerminalRescue';
const 探测超时Ms = 6000;
const 诊断竞速Ms = 3000;
const 渲染器脚本目录 = path.join(__dirname, 'renderer-scripts');
const 渲染器脚本缓存 = new Map();
const 逃逸冷却Ms = 10 * 60 * 1000;
// 载荷占位符 → 宿主侧值（与模块 PowerShell 模板同惯例：__名字__）。新增占位符必须同时登记在此，遗留会被下方残留校验拦下。
const 载荷占位符表 = { '__钥匙前缀__': () => 钥匙前缀, '__诊断竞速Ms__': () => String(诊断竞速Ms) };

/**
 * 注入 renderer 执行的三段载荷独立存为文件，不再内嵌字符串（可读可 diff、不会被模板字符串转义规则约束）：
 *   renderer-scripts/key-handover.js     帧内同步钥匙交接（拿 DI 容器里的终端服务引用与根容器）
 *   renderer-scripts/channel-diagnose.js 端口 pending / backend / 懒服务形态的只读取证
 *   renderer-scripts/channel-repair.js   就地外科修复（清悬挂 pending 重连 + 懒服务强制实例化）
 * 载入流程：读文件 → 去 BOM → 逐个替换占位符 → 残留中文占位符即报错。最后一步是硬约束：带占位符的坏脚本送进窗口只会
 * 得到一个难以归因的 SyntaxError（同类缺陷实测过：保活改名器模板占位符漏接，部署日志只说「模板未提供」，从未落位）。
 */
function 取渲染器脚本(文件名) {
	if (渲染器脚本缓存.has(文件名)) { return 渲染器脚本缓存.get(文件名); }
	const 全路径 = path.join(渲染器脚本目录, 文件名);
	let 文;
	try { 文 = fs.readFileSync(全路径, 'utf8'); }
	catch (错误) { throw new Error('渲染器载荷读取失败 ' + 全路径 + '：' + (错误 instanceof Error ? 错误.message : String(错误))); }
	文 = 文.replace(/^\uFEFF/, '');
	for (const [占位符, 取值] of Object.entries(载荷占位符表)) { 文 = 文.split(占位符).join(取值()); }
	const 残留 = /__[\u4e00-\u9fa5][\u4e00-\u9fa5A-Za-z0-9]*__/.exec(文);
	if (残留) { throw new Error('渲染器载荷 ' + 文件名 + ' 仍残留占位符 ' + 残留[0] + '（占位符表接线缺失？）'); }
	if (!文.trim()) { throw new Error('渲染器载荷 ' + 文件名 + ' 为空'); }
	渲染器脚本缓存.set(文件名, 文);
	return 文;
}
// ===================== L0：终端通道探针 =====================

/**
 * 探测本窗口终端通道死活。选项逐字复刻 Remote-SSH 连接终端（bundle 实证：
 * `{cwd: Uri.file(os.homedir()), name, shellPath: 本地 shell, shellArgs: ['/c', '(…) & exit /b 0'], hideFromUser: true, isTransient: true}`）。
 * 为什么必须复刻 cwd：`TerminalProcessManager` 按 **cwd 的 authority** 决定本地/远程（file URI → remoteAuthority=undefined），所以 Remote-SSH 的连接终端**恒为本地终端**——在已连接远程的窗口里也一样。探针走同一条路径，结果对「连接能否建立」有直接代表性。
 * ⚠️ 绝不能因窗口有 remoteName 就跳过探测：连接失败的窗口同样有 remoteName，跳过 = 在最需要它的场景里让整套救援失效。
 *
 * 判读三态：限时内 processId 落地 = 健康；限时内毫无回信 = 通道死（病征：窗口到 pty 宿主的直连 MessagePort 从未到达，`_connectToDirectProxy` 里的一次性 pending 被永久 await）；立即抛错 = 判定失败（shell 路径不存在等环境异常），不得当成死亡去触发破坏性救援。
 */
async function 探测终端通道(日志) {
	const 选项 = {
		name: '接管安装·终端探测',
		isTransient: true,
		hideFromUser: true,
		cwd: vscode.Uri.file(os.homedir()), // file URI → 走本地终端通道，与 Remote-SSH 同路径
	};
	if (process.platform === 'win32') {
		选项.shellPath = process.env.ComSpec || 'C:\\Windows\\System32\\cmd.exe';
		选项.shellArgs = ['/d', '/c', 'exit', '0'];
	} else {
		选项.shellPath = '/bin/sh';
		选项.shellArgs = ['-c', 'exit 0'];
	}
	const 超时哨兵 = Symbol('悬挂');
	let 终端 = null;
	try {
		终端 = vscode.window.createTerminal(选项);
		const 结果 = await Promise.race([
			终端.processId.then(
				pid => ({ 健康: true, pid }),
				错 => ({ 健康: false, 判定失败: true, 原因: 'processId 立即失败：' + (错 instanceof Error ? 错.message : String(错)) }),
			),
			new Promise(解 => setTimeout(() => 解(超时哨兵), 探测超时Ms)),
		]);
		if (结果 === 超时哨兵) {
			日志('探针：终端通道死亡——processId 限时 ' + 探测超时Ms + 'ms 毫无回信（创建请求未获 pty 宿主响应）');
			return { 健康: false, 悬挂: true, 原因: 'processId 限时未回信' };
		}
		if (结果.健康) { 日志('探针：终端通道健康（processId=' + 结果.pid + '）'); }
		else { 日志('探针：' + 结果.原因); }
		return 结果;
	} catch (错误) {
		const 原因 = 错误 instanceof Error ? 错误.message : String(错误);
		日志('探针：createTerminal 同步抛错（判定失败，非通道死亡）——' + 原因);
		return { 健康: false, 判定失败: true, 原因 };
	} finally {
		try { 终端?.dispose(); } catch { /* 已退出，忽略 */ }
	}
}

// ===================== L1：CDP 断点交接 + 就地修复（进本窗口 renderer 的 DI 容器） =====================

// 载荷与宿主的分工是硬约束：钥匙交接必须在断点帧内**同步**完成（拿到容器里的服务引用）；诊断与修复一律放到resume之后跑——帧被暂停期间页内 setTimeout 不走动，任何限时竞速都会被统一误判为超时（这条踩过坑）。
// 三段载荷本体存为独立文件（renderer-scripts/key-handover.js / channel-diagnose.js / channel-repair.js），由 取渲染器脚本() 在调用点载入并替换占位符，此处不再内嵌字符串。

/** 找出本窗口对应的 CDP target：标题须含本窗口工作区名；多窗口同名（歧义）或零命中都放弃，绝不误附着别的窗口。 */
async function 找本窗口目标(端口, 日志) {
	const 工作区名 = vscode.workspace.workspaceFolders?.[0]?.name;
	if (!工作区名) { 日志('L1 跳过：本窗口无工作区文件夹，无法唯一识别 CDP target'); return null; }
	const targets = await cdp.发现目标(端口);
	if (!targets?.length) { 日志('L1 跳过：CDP /json/list 无 page target'); return null; }
	const 命中 = targets.filter(t => (t.title || '').includes(工作区名));
	if (命中.length === 0) { 日志('L1 跳过：' + targets.length + ' 个 target 无一标题含「' + 工作区名 + '」（本窗口 renderer 未就绪？）'); return null; }
	if (命中.length > 1) { 日志('L1 跳过：' + 命中.length + ' 个 target 标题都含「' + 工作区名 + '」，歧义不附着'); return null; }
	return 命中[0];
}

/** 从 target.url 推导 workbench bundle 的磁盘路径（vscode-file://vscode-app/<版本目录>/resources/app/out/...）。 */
function 推bundle路径(targetUrl) {
	try {
		const 解码 = decodeURIComponent(String(targetUrl).replace('vscode-file://vscode-app/', ''));
		const 锚 = 解码.indexOf('/resources/app/out/');
		if (锚 < 0) { return null; }
		const bundle = 解码.slice(0, 锚).replace(/\//g, path.sep) + path.join('resources', 'app', 'out', 'vs', 'workbench', 'workbench.desktop.main.js');
		return fs.existsSync(bundle) ? bundle : null;
	} catch { return null; }
}

/**
 * L1 深诊断 + 就地修复：载入三段渲染器载荷 → 断点交接拿钥匙 → 诊断载荷限时只读取证 →（可选）修复载荷就地外科修复。
 * 返回 { 诊断, 修复 }（诊断必得——这是下次复发时定位卡点的金证据；修复是尽力而为）。
 * 载荷缺失或占位符未接线时如实记日志并返回 null（不静默降级、不把带占位符的坏脚本送进窗口）。
 */
async function 经CDP诊断并修复(日志, 做修复) {
	// 载荷先行载入（含占位符替换与残留校验）：文件不见或接线遗漏在这里就报错返回
	let 钥匙载荷, 诊断载荷, 修复载荷 = null;
	try {
		钥匙载荷 = 取渲染器脚本('key-handover.js');
		诊断载荷 = 取渲染器脚本('channel-diagnose.js');
		if (做修复) { 修复载荷 = 取渲染器脚本('channel-repair.js'); }
	} catch (错误) { 日志('L1 跳过：' + (错误 instanceof Error ? 错误.message : String(错误))); return null; }
	const argv路径 = cdp.解析argv路径();
	const 现状 = cdp.读取调试端口(argv路径);
	if (!现状.已有) { 日志('L1 跳过：argv.json 未配置 remote-debugging-port（本机 Chat 注入器扩展会写入；也可手动加 "remote-debugging-port": "17890" 后彻底重启）'); return null; }
	if (!(await cdp.探测调试端口(现状.端口))) { 日志('L1 跳过：调试端口 ' + 现状.端口 + ' 未监听（argv.json 配置后需彻底重启 VS Code 主进程）'); return null; }
	const target = await 找本窗口目标(现状.端口, 日志);
	if (!target) { return null; }
	const bundle路径 = 推bundle路径(target.url);
	if (!bundle路径) { 日志('L1 跳过：无法从 target.url 推导 workbench bundle 磁盘路径'); return null; }
	let src;
	try { src = fs.readFileSync(bundle路径, 'utf8'); } catch (e) { 日志('L1 跳过：读 bundle 失败 ' + e.message); return null; }
	const 锚 = /(?<![\.\w])invokeFunction\s*\([^)]*\)\s*\{/.exec(src);
	if (!锚) { 日志('L1 跳过：bundle 里找不到 invokeFunction 定义（版本漂移）'); return null; }
	const 之前 = src.slice(0, 锚.index);
	const 断点行 = (之前.match(/\n/g) || []).length;
	const 断点列 = 锚.index - (之前.lastIndexOf('\n') + 1) + 锚[0].indexOf('{') + 1;
	日志('CDP 附着 target「' + (target.title || '').slice(0, 60) + '」，invokeFunction 锚点 line ' + 断点行 + ' col ' + 断点列);

	const 会话 = new cdp.CDP会话(target, target.webSocketDebuggerUrl);
	let 已交接 = false;
	let 暂停处理 = null; let 心跳 = null; let 断点Id = null; let 调试器已开 = false;
	try {
		await 会话.等待就绪(5000);
		await 会话.send('Runtime.enable', {}, 5000);
		await 会话.send('Runtime.evaluate', { expression: `delete globalThis['${钥匙前缀}.installed']; delete globalThis['${钥匙前缀}.refs']; delete globalThis['${钥匙前缀}.ids']; delete globalThis['${钥匙前缀}.root']; true`, returnByValue: true }, 5000);
		const scripts = [];
		会话.on事件('Debugger.scriptParsed', p => scripts.push(p));
		await 会话.send('Debugger.enable', {}, 5000);
		调试器已开 = true;
		await new Promise(r => setTimeout(r, 1200)); // 等 scriptParsed 重放
		const bundle = scripts.find(s => /workbench\.desktop\.main\.js/.test(s.url || ''));
		if (!bundle) { 日志('L1 放弃：scriptParsed 重放里没有 workbench bundle'); return null; }

		// 暂停收集器先于布点订阅；捕获+resume 全在处理器内完成（防 v6 式死锁：输入/派发回执会被暂停卡死）
		let 捕获中 = false;
		let 交接完成 = null;
		const 交接Promise = new Promise(res => { 交接完成 = res; });
		const 摘暂停 = 会话.on事件('Debugger.paused', params => {
			const 命中 = (params.hitBreakpoints || []).includes(断点Id);
			if (!命中) { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); return; }
			if (捕获中) { return; }
			捕获中 = true;
			(async () => {
				try {
					const frameId = params.callFrames?.[0]?.callFrameId;
					const ev = await 会话.send('Debugger.evaluateOnCallFrame', { callFrameId: frameId, expression: 钥匙载荷, returnByValue: true }, 8000);
					const 值 = ev?.result?.value;
					日志('钥匙交接 => ' + JSON.stringify(值));
					交接完成(值 && (值.ok || 值.already) ? 值 : null);
				} catch (e) { 日志('钥匙交接异常：' + e.message); 交接完成(null); }
				finally { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); }
			})();
		});
		try {
			const resp = await 会话.send('Debugger.setBreakpoint', { location: { scriptId: bundle.scriptId, lineNumber: 断点行, columnNumber: 断点列 }, condition: `!globalThis['${钥匙前缀}.installed']` }, 5000);
			断点Id = resp.breakpointId;
			// 主动撞击：内置 noop 命令经本窗口扩展宿主派发 → 本窗口 CommandService → invokeFunction 必撞（零副作用；只撞本窗口，误附着别的窗口时会等不到命中自然超时，不会祸及旁人）
			const 撞一次 = () => { vscode.commands.executeCommand('noop').catch(() => {}); };
			撞一次();
			心跳 = setInterval(撞一次, 800);
			const 结果 = await Promise.race([交接Promise, new Promise(res => setTimeout(() => res('超时'), 8000))]);
			if (结果 !== '超时') { 已交接 = !!结果; }
			else { 日志('L1 放弃：8 秒内断点未命中（窗口渲染进程无响应？）'); }
		} finally {
			if (心跳) { clearInterval(心跳); 心跳 = null; }
			try { 摘暂停(); } catch { /* 忽略 */ }
			try { if (断点Id) { await 会话.send('Debugger.removeBreakpoint', { breakpointId: 断点Id }, 5000).catch(() => {}); } } catch { /* 忽略 */ }
			try { await 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); } catch { /* 忽略 */ }
			try { await 会话.send('Debugger.disable', {}, 5000).catch(() => {}); } catch { /* 忽略 */ }
		}
		if (!已交接) { return null; }

		// resume 后：诊断（限时读取）与可选修复都走普通 Runtime.evaluate
		const 诊断ev = await 会话.send('Runtime.evaluate', { expression: 诊断载荷, returnByValue: true, awaitPromise: true }, 25000);
		const 诊断 = 诊断ev?.result?.value ?? { err: '诊断载荷无返回', 异常: 诊断ev?.exceptionDetails?.text };
		日志('L1 诊断报告: ' + JSON.stringify(诊断));
		let 修复 = null;
		if (做修复) {
			const 修复ev = await 会话.send('Runtime.evaluate', { expression: 修复载荷, returnByValue: true, awaitPromise: true }, 25000);
			修复 = 修复ev?.result?.value ?? { err: '修复载荷无返回' };
			日志('L1 修复尝试: ' + JSON.stringify(修复));
		}
		return { 诊断, 修复 };
	} catch (e) {
		日志('L1 异常：' + (e instanceof Error ? e.message : String(e)));
		return null;
	} finally {
		// 兜底放行：resume 万一失败，断开调试 WS（V8 在调试客户端断开时自动恢复被暂停的页面），绝不让窗口卡死在 paused
		try { 会话.dispose(); } catch { /* 忽略 */ }
	}
}

// ===================== L3：自动逃逸（新窗口重开远程） =====================

/** 当前窗口指向的远程主机名：remoteName（已连接）或工作区文件夹 authority 的 ssh-remote+<hex>（挂起中/失败的连接）→ 解码十六进制。 */
function 当前窗口远程主机() {
	try {
		const 解码hex = s => { const b = Buffer.from(s, 'hex'); return b.toString('utf8'); };
		if (vscode.env.remoteName && vscode.env.remoteName.startsWith('ssh-remote+')) { return 解码hex(vscode.env.remoteName.slice('ssh-remote+'.length)); }
		const uri = vscode.workspace.workspaceFolders?.[0]?.uri;
		if (uri && uri.scheme === 'vscode-remote' && typeof uri.authority === 'string' && uri.authority.startsWith('ssh-remote+')) {
			return 解码hex(uri.authority.slice('ssh-remote+'.length));
		}
	} catch { /* 解码失败按无远程处理 */ }
	return null;
}

/** 把诊断/救援报告落盘 %TEMP%（下次复发时的取证材料），best-effort。 */
function 报告写盘(报告) {
	try {
		const 文件 = path.join(os.tmpdir(), 'vsi-terminal-rescue-report.json');
		const 旧 = (() => { try { return JSON.parse(fs.readFileSync(文件, 'utf8')); } catch { return { 历史: [] }; } })();
		const 历史 = Array.isArray(旧.历史) ? 旧.历史.slice(-9) : [];
		历史.push(报告);
		fs.writeFileSync(文件, JSON.stringify({ 历史 }, null, 2), 'utf8');
		return 文件;
	} catch { return null; }
}

/**
 * 救援阶梯总编排。返回 { 结果: '健康'|'判定失败'|'L1就地修复'|'L2重启pty宿主'|'已逃逸'|'救援失败', 详情 }。
 * @param 主机 逃逸时新窗口要重开的远程主机（缺省自动取当前窗口指向的主机）
 * @param 选项 { 手动 } —— 手动命令触发时跳过逃逸冷却（用户意图明确）
 */
async function 救援终端通道(context, 主机, 日志, 选项) {
	const 时间线 = [];
	const 记 = s => { 时间线.push(s); 日志(s); };

	// L0 探测
	let 探 = await 探测终端通道(记);
	if (探.健康) { return { 结果: '健康', 详情: 探 }; }
	if (探.判定失败) {
		// 立即报错（shell 路径不存在等）说明是判定条件坏了，不是通道死——绝不能据此触发破坏性救援（重启 pty 宿主/开新窗口）
		记('探针判定失败（' + 探.原因 + '），不构成通道死亡证据，放弃救援');
		return { 结果: '判定失败', 详情: { 探, 时间线 } };
	}
	记('终端通道确认死亡（processId 无回信），进入救援阶梯');

	// L1：CDP 深诊断 + 外科式就地修复（对症病灶：清空永久悬挂的 pty 宿主直连 pending 并重连；取证必做，端口不在线自动跳过）
	// 之所以排在 restartPtyHost 之前：它只动本窗口内部状态，不重启 pty 宿主、不干扰其它窗口与存活终端。
	const L1 = await 经CDP诊断并修复(记, true);
	if (L1) {
		await new Promise(r => setTimeout(r, 1500));
		探 = await 探测终端通道(记);
		if (探.健康) {
			报告写盘({ 时刻: new Date().toISOString(), 结果: 'L1就地修复', L1, 时间线 });
			return { 结果: 'L1就地修复', 详情: { L1, 时间线 } };
		}
	}

	// L2：重启 pty 宿主（重锤）——backend 的 onPtyHostRestart 处理会清空直连代理与 pending 并重新取端口，
	// 故对「端口路径已坏死、就地重连也拉不回」的病态仍有救；代价是本机 pty 宿主重启、各窗口本地终端由 VS Code 自动重连/重启。
	try {
		await vscode.commands.executeCommand('workbench.action.terminal.restartPtyHost');
		记('L2 已执行 restartPtyHost，等待 4 秒后复探');
		await new Promise(r => setTimeout(r, 4000));
		探 = await 探测终端通道(记);
		if (探.健康) {
			报告写盘({ 时刻: new Date().toISOString(), 结果: 'L2重启pty宿主', L1, 时间线 });
			return { 结果: 'L2重启pty宿主', 详情: { L1, 时间线 } };
		}
	} catch (e) { 记('L2 执行失败：' + (e instanceof Error ? e.message : String(e))); }

	// L3：自动逃逸（实测 100% 有效：新窗口 = 全新的 pty 宿主端口绑定）
	const 目标主机 = 主机 || 当前窗口远程主机();
	const 报告文件 = 报告写盘({ 时刻: new Date().toISOString(), 结果: '待逃逸', L1, 时间线 });
	if (!目标主机) {
		记('L3 无法逃逸：本窗口不指向任何远程主机，需要手动处理');
		return { 结果: '救援失败', 详情: { L1, 时间线, 报告文件 } };
	}
	const 冷却键 = '终端逃逸冷却.' + 目标主机;
	const 上次逃逸 = context.globalState.get(冷却键, 0);
	if (!选项?.手动 && Date.now() - 上次逃逸 < 逃逸冷却Ms) {
		记('L3 冷却中（' + Math.round((逃逸冷却Ms - (Date.now() - 上次逃逸)) / 1000) + ' 秒后可再逃逸）');
		return { 结果: '救援失败', 详情: { L1, 时间线, 报告文件, 冷却中: true } };
	}
	context.globalState.update(冷却键, Date.now());
	const authority = 'ssh-remote+' + Buffer.from(目标主机, 'utf8').toString('hex');
	try {
		await vscode.commands.executeCommand('vscode.open', vscode.Uri.parse('vscode-remote://' + authority + '/'));
		记('L3 已在新窗口重开远程「' + 目标主机 + '」');
		return { 结果: '已逃逸', 详情: { 主机: 目标主机, L1, 时间线, 报告文件 } };
	} catch (e) {
		记('L3 打开新窗口失败：' + (e instanceof Error ? e.message : String(e)));
		return { 结果: '救援失败', 详情: { L1, 时间线, 报告文件 } };
	}
}

module.exports = { 探测终端通道, 经CDP诊断并修复, 救援终端通道, 当前窗口远程主机, 报告写盘, 取渲染器脚本, 钥匙前缀 };
// 三段载荷以懒加载属性导出：仓库 _probe 自测 harness 靠它在 VS Code 之外直接对活窗口验证载荷本体。
// 用 getter 而不是启动即读：让「载荷文件缺失/占位符未接线」只在真正走到注入时才报错，不在 require 阶段拖垮扩展激活。
Object.defineProperties(module.exports, {
	脚本_钥匙: { get: () => 取渲染器脚本('key-handover.js'), enumerable: true },
	脚本_诊断: { get: () => 取渲染器脚本('channel-diagnose.js'), enumerable: true },
	脚本_修复: { get: () => 取渲染器脚本('channel-repair.js'), enumerable: true },
});
