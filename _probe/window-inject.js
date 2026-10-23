// 窗口内注入 harness：附着指定窗口的 renderer，复用生产同款钥匙交接拿到 DI 容器引用，
// 然后按顺序执行若干探针载荷（_probe/payloads/*.js），载荷返回的对象原样打印并落盘。
// 与 cdp-selftest.js 的差异：那是「验证载荷能不能跑」，这个是「进窗口里扫真实状态并就地改」。
// 用法：
//   node _probe/window-inject.js <端口> <标题特征> [--workers] [--no-key] [payload1 payload2 ...]
//   --workers   不进 page，改逐个附着 worker target 做只读探查（判它是不是扩展宿主）
//   --no-key    跳过钥匙交接（载荷不依赖 DI 容器引用时用）
// 说明：钥匙载荷幂等（installed 即返回 already），所以已交接过的窗口直接跳过断点撞击。
'use strict';
const fs = require('fs');
const pathMod = require('path');
const Module = require('module');

const 原解析 = Module._resolveFilename;
Module._resolveFilename = function (request, ...args) {
	if (request === 'vscode') { return pathMod.join(__dirname, '_vscode_stub_full.js'); }
	return 原解析.call(this, request, ...args);
};
const 救援 = require('../接管远程服务器安装扩展/terminalRescue.js');
const cdp = require('../接管远程服务器安装扩展/cdp.js');

const 载荷目录 = pathMod.join(__dirname, 'payloads');
const 钥匙前缀 = 救援.钥匙前缀;
const 诊断竞速Ms = 3000;
const 日志 = (...a) => console.log(...a);

/** 与生产 取渲染器脚本 同款规则：替换占位符 + 残留即报错（带占位符的坏载荷送进窗口只会得到难以归因的 SyntaxError）。 */
const 默认扫描过滤 = 'terminal|extHost|mainThread|remoteAgent|ipc|channel|socket|mainProcess|persisted|exec|pty|instantiation|environment';
function 读载荷(文件名) {
	const 全路径 = pathMod.isAbsolute(文件名) ? 文件名 : pathMod.join(载荷目录, 文件名);
	let 文 = fs.readFileSync(全路径, 'utf8').replace(/^\uFEFF/, '');
	文 = 文.split('__钥匙前缀__').join(钥匙前缀);
	文 = 文.split('__诊断竞速Ms__').join(String(诊断竞速Ms));
	文 = 文.split('__扫描过滤__').join(String(process.env.VSI_SCAN_FILTER || 默认扫描过滤));
	// 本地目录：复刻 Remote-SSH 连接终端的 cwd（本地 homedir），页面内没有 node，只能由 harness 注入。
	// 必须转义反斜杠：直接塞进页面的单引号字面量里，'C:\Users\vhtmf' 会被 JS 当转义吃掉（\U→U）变成错路径。
	const 本地目录 = String(process.env.VSI_LOCAL_DIR || process.env.USERPROFILE || process.env.HOME || '');
	文 = 文.split('__本地目录__').join(本地目录.replace(/\\/g, '\\\\'));
	// 是否允许载荷绕过工作区信任门直调 createProcess（诊断用）：载荷里一律写成 '__绕过信任__' === 'true' 的字符串比对，默认不绕
	文 = 文.split('__绕过信任__').join(String(process.env.VSI_BYPASS_TRUST === '1' ? 'true' : 'false'));
	// 修复类载荷的阶段开关：默认只报告（report），绝不擅自改状态；需要改时才显式传 VSI_STAGES
	文 = 文.split('__阶段__').join(String(process.env.VSI_STAGES || 'report'));
	const 残留 = /__[\u4e00-\u9fa5][\u4e00-\u9fa5A-Za-z0-9]*__/.exec(文);
	if (残留) { throw new Error('载荷 ' + 文件名 + ' 残留占位符 ' + 残留[0]); }
	if (!文.trim()) { throw new Error('载荷 ' + 文件名 + ' 为空'); }
	return 文;
}

async function 列出目标(端口) {
	const targets = await cdp.发现目标(端口);
	if (!targets) { throw new Error('调试端口 ' + 端口 + ' 未在线'); }
	return targets;
}

/** 附着 bundle 锚点交接钥匙：复刻 terminalRescue/cdp-selftest 的断点手法，但只在「尚未交接」时才做。 */
async function 交接钥匙(会话, 日志) {
	const 已装 = await 会话.send('Runtime.evaluate', {
		expression: '(!!(globalThis["' + 钥匙前缀 + '.refs"] && globalThis["' + 钥匙前缀 + '.root"]))',
		returnByValue: true,
	}, 6000).catch(() => null);
	if (已装 && 已装.result && 已装.result.value) {
		const 现状 = await 会话.send('Runtime.evaluate', {
			expression: '(function(){var r=globalThis["' + 钥匙前缀 + '.refs"];return {keys:Object.keys(r||{}),entries:0};})()',
			returnByValue: true,
		}, 6000).catch(() => null);
		日志('钥匙已在窗口内（跳过断点交接）：' + JSON.stringify(现状 && 现状.result && 现状.result.value));
		return true;
	}
	const target = 会话.目标;
	const 解码 = decodeURIComponent(String(target.url).replace('vscode-file://vscode-app/', ''));
	const 锚位 = 解码.indexOf('/resources/app/out/');
	if (锚位 < 0) { 日志('无法从 target.url 推导 bundle 路径'); return false; }
	const bundle路径 = 解码.slice(0, 锚位).replace(/\//g, '\\') + '\\resources\\app\\out\\vs\\workbench\\workbench.desktop.main.js';
	const src = fs.readFileSync(bundle路径, 'utf8');
	const 锚 = /(?<![\.\w])invokeFunction\s*\([^)]*\)\s*\{/.exec(src);
	if (!锚) { 日志('bundle 里找不到 invokeFunction（版本漂移）'); return false; }
	const 之前 = src.slice(0, 锚.index);
	const 断点行 = (之前.match(/\n/g) || []).length;
	const 断点列 = 锚.index - (之前.lastIndexOf('\n') + 1) + 锚[0].indexOf('{') + 1;
	日志('bundle 锚点 line ' + 断点行 + ' col ' + 断点列);

	let bpId = null, 捕获中 = false, 交接完成 = null;
	const 交接Promise = new Promise(res => 交接完成 = res);
	const key = (vk, code, k) => {
		const b = { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, code, key: k };
		会话.send('Input.dispatchKeyEvent', Object.assign({ type: 'rawKeyDown' }, b), 5000).catch(() => { });
		setTimeout(() => 会话.send('Input.dispatchKeyEvent', Object.assign({ type: 'keyUp' }, b), 5000).catch(() => { }), 30);
	};
	const scripts = [];
	会话.on事件('Debugger.scriptParsed', p => scripts.push(p));
	await 会话.send('Debugger.enable', {}, 6000);
	await new Promise(r => setTimeout(r, 1000));
	const bundle = scripts.find(s => /workbench\.desktop\.main\.js/.test(s.url || ''));
	if (!bundle) { await 会话.send('Debugger.disable', {}, 5000).catch(() => { }); 日志('scriptParsed 里没有 workbench bundle'); return false; }
	const 摘暂停 = 会话.on事件('Debugger.paused', params => {
		const 命中 = (params.hitBreakpoints || []).includes(bpId);
		if (!命中) { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => { }); return; }
		if (捕获中) { return; }
		捕获中 = true;
		(async () => {
			try {
				const ev = await 会话.send('Debugger.evaluateOnCallFrame', {
					callFrameId: params.callFrames && params.callFrames[0] && params.callFrames[0].callFrameId,
					expression: 救援.取渲染器脚本('key-handover.js'),
					returnByValue: true,
				}, 8000);
				日志('钥匙交接 => ' + JSON.stringify(ev && ev.result && ev.result.value));
				const 值 = ev && ev.result && ev.result.value;
				交接完成(值 && (值.ok || 值.already) ? 值 : null);
			} catch (e) { 日志('钥匙交接异常: ' + e.message); 交接完成(null); }
			finally { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => { }); }
		})();
	});
	try {
		const resp = await 会话.send('Debugger.setBreakpoint', {
			location: { scriptId: bundle.scriptId, lineNumber: 断点行, columnNumber: 断点列 },
			condition: "!globalThis['" + 钥匙前缀 + ".installed']",
		}, 6000);
		bpId = resp.breakpointId;
		key(112, 'F1', 'F1');
		let 结果 = null;
		for (let i = 1; i <= 4 && !结果; i++) {
			结果 = await Promise.race([交接Promise, new Promise(res => setTimeout(() => res('超时'), 4000))]);
			if (结果 === '超时') { 结果 = null; 日志('撞击 ' + i + ' 未命中'); key(27, 'Escape', 'Escape'); await new Promise(r => setTimeout(r, 400)); }
			else 日志('撞击 ' + i + ' 完成');
		}
		if (!结果) { return false; }
	} finally {
		try { if (bpId) await 会话.send('Debugger.removeBreakpoint', { breakpointId: bpId }, 5000).catch(() => { }); } catch { }
		try { await 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => { }); } catch { }
		try { await 会话.send('Debugger.disable', {}, 5000).catch(() => { }); } catch { }
		try { 摘暂停(); } catch { }
		try { key(27, 'Escape', 'Escape'); } catch { }
	}
	await new Promise(r => setTimeout(r, 400));
	return true;
}

async function 探查Worker(端口) {
	// cdp.发现目标() 只返回 page，worker/utility 一律看不到；这里直接读原始 /json/list 才能判扩展宿主是否可及
	const http = require('http');
	const 原文 = await new Promise((resolve, reject) => {
		const req = http.get({ host: '127.0.0.1', port: 端口, path: '/json/list' }, res => {
			let buf = ''; res.on('data', d => buf += d); res.on('end', () => resolve(buf));
		});
		req.on('error', reject);
		req.setTimeout(4000, () => req.destroy(new Error('/json/list 超时')));
	});
	const 全部 = JSON.parse(原文);
	日志('原始 target 数: ' + 全部.length);
	const workers = 全部.filter(t => String(t.type || '').toLowerCase() !== 'page');
	日志('非 page 的 target: ' + workers.length);
	for (const t of workers) {
		const 会话 = new cdp.CDP会话(t, t.webSocketDebuggerUrl);
		let 值 = null, 错 = null;
		try {
			await 会话.等待就绪(6000);
			await 会话.send('Runtime.enable', {}, 6000);
			const ev = await 会话.send('Runtime.evaluate', {
				expression: '(function(){try{'
					+ 'var 有node=(typeof process!=="undefined");'
					+ 'var o={type:"' + String(t.type) + '",node:有node};'
					+ 'if(有node){o.类型=process.type;o.pid=process.pid;o.argv=(process.argv||[]).slice(1,5).join(" ");'
					+ 'o.execArgv=(process.execArgv||[]).join(" ");'
					+ 'o.有require=(typeof require==="function");'
					+ 'o.有扩展宿主标记=(!!(globalThis.vscode||globalThis.__extensions||globalThis._VSCODE_NODE_MODULES));}'
					+ 'o.globals=Object.keys(globalThis).slice(0,45).join(",");'
					+ 'return o;}catch(e){return {fatal:String(e&&e.message||e)};}})()',
				returnByValue: true,
			}, 8000);
			值 = ev && ev.result && ev.result.value;
		} catch (e) { 错 = String(e && e.message || e); }
		finally { try { 会话.dispose(); } catch { } }
		日志('--- ' + String(t.type) + '  title=' + String(t.title || '').slice(0, 40) + '  url=' + String(t.url || '').slice(0, 70));
		if (错) { 日志('    探测失败: ' + 错); } else { 日志('    ' + JSON.stringify(值)); }
	}
}

(async () => {
	const 参数 = process.argv.slice(2);
	const 端口 = Number(参数[0] || 17890);
	const 特征 = 参数[1] || '';
	const 要workers = 参数.indexOf('--workers') >= 0;
	const 不交接 = 参数.indexOf('--no-key') >= 0;
	const 静默 = 参数.indexOf('--quiet') >= 0;
	const 载荷名 = 参数.filter((a, i) => i >= 2 && a.indexOf('--') !== 0);
	try {
		if (要workers) { await 探查Worker(端口); process.exit(0); }
		const targets = await 列出目标(端口);
		const 命中 = targets.filter(x => (x.title || '').includes(特征));
		if (命中.length !== 1) {
			日志('标题特征「' + 特征 + '」命中 ' + 命中.length + ' 个 target（需唯一）：');
			targets.forEach(t => 日志('  [' + t.type + '] ' + String(t.title || '').slice(0, 80)));
			process.exit(1);
		}
		const target = 命中[0];
		日志('=== 附着窗口: ' + String(target.title || '').slice(0, 90));
		const 会话 = new cdp.CDP会话(target, target.webSocketDebuggerUrl);
		会话.目标 = target;
		await 会话.等待就绪(8000);
		await 会话.send('Runtime.enable', {}, 6000);
		if (!不交接 && 载荷名.length > 0) {
			if (!(await 交接钥匙(会话, 日志))) { 日志('钥匙交接失败，载荷将只能读到已存在的引用'); }
		}
		let 累计失败 = 0;
		for (const 名 of 载荷名) {
			日志('');
			日志('########## 载荷: ' + 名);
			let 文;
			try { 文 = 读载荷(名); } catch (e) { 日志('载荷载入失败: ' + e.message); 累计失败++; continue; }
			try {
				// 求值超时：常规探针 90 秒够用，但"重解析远程权威"这类要等 ssh 建链的载荷可能几分钟 → 由环境变量放宽
				const 求值超时 = Number(process.env.VSI_EVAL_TIMEOUT_MS || 90000);
				const ev = await 会话.send('Runtime.evaluate', { expression: 文, returnByValue: true, awaitPromise: true }, 求值超时);
				const 值 = ev && ev.result && ev.result.value;
				const 文出 = JSON.stringify(值 === undefined ? { err: '无返回', 异常: ev && ev.exceptionDetails } : 值, null, 2);
				const 落 = pathMod.join(process.env.TEMP || require('os').tmpdir(), 'vsi-inject-' + 名.replace(/[^A-Za-z0-9_.-]/g, '_') + '.json');
				fs.writeFileSync(落, 文出, 'utf8');
				if (静默) {
					// 只打摘要，全文落盘由调用方按需 grep（容器级扫描动辄几百行，直接刷屏会淹掉线索）
					const 摘 = (值 && typeof 值 === 'object') ? Object.keys(值).map(k => {
						const v = 值[k];
						return k + '=' + (Array.isArray(v) ? ('组' + v.length) : (v === null || typeof v !== 'object' ? String(v) : 'obj'));
					}).join('  ') : String(值);
					日志('摘要: ' + 摘);
				} else {
					日志(文出);
				}
				日志('结果已写 ' + 落 + '（' + fs.statSync(落).size + ' 字节）');
			} catch (e) {
				日志('载荷执行失败: ' + (e && e.message || e));
				累计失败++;
			}
		}
		try { 会话.dispose(); } catch { }
		setTimeout(() => process.exit(累计失败 === 0 ? 0 : 1), 250);
	} catch (e) {
		日志('harness 异常: ' + (e && e.stack || e));
		process.exit(1);
	}
})();
