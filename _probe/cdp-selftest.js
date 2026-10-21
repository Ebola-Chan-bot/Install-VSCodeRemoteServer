// 自测 harness：在 VS Code 之外直接验证 terminalRescue.js 的三段 CDP 脚本载荷（钥匙/诊断/修复）对真实活窗口可用。
// 流程复刻 经CDP诊断并修复()，唯一差异：撞击用 CDP 合成 F1（harness 不在扩展宿主里，没法执行 noop 命令）。
// 用法：node cdp-selftest.js <port> <窗口标题特征> [不修复]
'use strict';
const fs = require('fs');
const pathMod = require('path');
const Module = require('module');

// vscode 模块桩：用同目录完整桩，让 terminalRescue.js 能在纯 node 下被 require
const 原解析 = Module._resolveFilename;
Module._resolveFilename = function (request, ...args) {
	if (request === 'vscode') { return pathMod.join(__dirname, '_vscode_stub_full.js'); }
	return 原解析.call(this, request, ...args);
};

const 救援 = require('../接管远程服务器安装扩展/terminalRescue.js');
const cdp = require('../接管远程服务器安装扩展/cdp.js');
const log = (...a) => console.log(...a);

const PORT = Number(process.argv[2] || 17890);
const MATCH = process.argv[3] || '上科大B服务器';
const 做修复 = process.argv[4] !== '不修复';

(async () => {
	// 1) 找 target
	const targets = await cdp.发现目标(PORT);
	if (!targets) { log('端口未在线'); process.exit(1); }
	const t = targets.filter(x => (x.title || '').includes(MATCH));
	if (t.length !== 1) { log('标题特征命中 ' + t.length + ' 个 target，需唯一'); process.exit(1); }
	const target = t[0];
	log('=== target:', target.title.slice(0, 70));

	// 2) 推 bundle 路径、定位锚点（与 terminalRescue 同法）
	const 解码 = decodeURIComponent(String(target.url).replace('vscode-file://vscode-app/', ''));
	const 锚位 = 解码.indexOf('/resources/app/out/');
	const bundle路径 = 解码.slice(0, 锚位).replace(/\//g, '\\') + '\\resources\\app\\out\\vs\\workbench\\workbench.desktop.main.js';
	const src = fs.readFileSync(bundle路径, 'utf8');
	const 锚 = /(?<![\.\w])invokeFunction\s*\([^)]*\)\s*\{/.exec(src);
	const 之前 = src.slice(0, 锚.index);
	const 断点行 = (之前.match(/\n/g) || []).length;
	const 断点列 = 锚.index - (之前.lastIndexOf('\n') + 1) + 锚[0].indexOf('{') + 1;
	log('bundle:', bundle路径.slice(-60), '锚点 line', 断点行, 'col', 断点列);

	// 3) 附着 + 布点（护栏与 terminalRescue 相同：先订阅 paused，捕获+resume 在处理器内完成）
	const 会话 = new cdp.CDP会话(target, target.webSocketDebuggerUrl);
	let bpId = null, 捕获中 = false, 交接完成 = null;
	const 交接Promise = new Promise(res => 交接完成 = res);
	try {
		await 会话.等待就绪(5000);
		await 会话.send('Runtime.enable', {}, 5000);
		const key = (vk, code, k) => { const b = { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, code, key: k }; 会话.send('Input.dispatchKeyEvent', Object.assign({ type: 'rawKeyDown' }, b), 5000).catch(() => {}); setTimeout(() => 会话.send('Input.dispatchKeyEvent', Object.assign({ type: 'keyUp' }, b), 5000).catch(() => {}), 30); };
		key(27, 'Escape', 'Escape'); // 先收残留面板
		await new Promise(r => setTimeout(r, 400));
		await 会话.send('Runtime.evaluate', { expression: `delete globalThis['${救援.钥匙前缀}.installed']; delete globalThis['${救援.钥匙前缀}.refs']; delete globalThis['${救援.钥匙前缀}.ids']; delete globalThis['${救援.钥匙前缀}.root']; true`, returnByValue: true }, 5000);
		const scripts = [];
		会话.on事件('Debugger.scriptParsed', p => scripts.push(p));
		await 会话.send('Debugger.enable', {}, 5000);
		await new Promise(r => setTimeout(r, 1200));
		const bundle = scripts.find(s => /workbench\.desktop\.main\.js/.test(s.url || ''));
		if (!bundle) { log('scriptParsed 无 bundle'); process.exit(1); }

		const 摘暂停 = 会话.on事件('Debugger.paused', params => {
			const 命中 = (params.hitBreakpoints || []).includes(bpId);
			if (!命中) { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); return; }
			if (捕获中) { return; }
			捕获中 = true;
			(async () => {
				try {
					const ev = await 会话.send('Debugger.evaluateOnCallFrame', { callFrameId: params.callFrames?.[0]?.callFrameId, expression: 救援.脚本_钥匙, returnByValue: true }, 8000);
					log('钥匙交接 =>', JSON.stringify(ev?.result?.value));
					const 值 = ev?.result?.value;
					交接完成(值 && (值.ok || 值.already) ? 值 : null);
				} catch (e) { log('钥匙交接异常:', e.message); 交接完成(null); }
				finally { 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); }
			})();
		});
		try {
			const resp = await 会话.send('Debugger.setBreakpoint', { location: { scriptId: bundle.scriptId, lineNumber: 断点行, columnNumber: 断点列 }, condition: `!globalThis['${救援.钥匙前缀}.installed']` }, 5000);
			bpId = resp.breakpointId;
			log('断点绑定 =>', JSON.stringify(resp.actualLocation));
			let 结果 = null;
			for (let i = 1; i <= 4 && !结果; i++) {
				key(112, 'F1', 'F1');
				结果 = await Promise.race([交接Promise, new Promise(res => setTimeout(() => res('超时'), 3500))]);
				if (结果 === '超时') { 结果 = null; log('撞击', i, '未命中'); key(27, 'Escape', 'Escape'); await new Promise(r => setTimeout(r, 400)); }
				else log('撞击', i, '完成');
			}
			if (!结果) { log('钥匙交接失败'); process.exit(1); }
		} finally {
			try { if (bpId) await 会话.send('Debugger.removeBreakpoint', { breakpointId: bpId }, 5000).catch(() => {}); } catch {}
			try { await 会话.send('Debugger.resume', { terminateOnResume: false }, 5000).catch(() => {}); } catch {}
			try { await 会话.send('Debugger.disable', {}, 5000).catch(() => {}); } catch {}
			try { 摘暂停(); } catch {}
			try { key(27, 'Escape', 'Escape'); } catch {}
		}
		await new Promise(r => setTimeout(r, 400));

		// 4) 诊断（resume 后，setTimeout 已恢复走动）
		const 诊断ev = await 会话.send('Runtime.evaluate', { expression: 救援.脚本_诊断, returnByValue: true, awaitPromise: true }, 25000);
		const 诊断 = 诊断ev?.result?.value ?? { err: '无返回', 异常: 诊断ev?.exceptionDetails };
		log('\n===== 诊断报告 =====\n' + JSON.stringify(诊断, null, 2));

		// 5) 修复脚本（健康窗口上 = 强制实例化懒 localPtyService，安全性等同首次开终端）
		let 修复 = null;
		if (做修复) {
			const 修复ev = await 会话.send('Runtime.evaluate', { expression: 救援.脚本_修复, returnByValue: true, awaitPromise: true }, 25000);
			修复 = 修复ev?.result?.value ?? { err: '无返回' };
			log('\n===== 修复尝试 =====\n' + JSON.stringify(修复, null, 2));
		}
		fs.writeFileSync(pathMod.join(process.env.TEMP, 'vsi-selftest.json'), JSON.stringify({ 诊断, 修复 }, null, 2), 'utf8');
		log('\n结果已写 %TEMP%\\vsi-selftest.json');
	} catch (e) {
		log('harness 异常:', e.message);
	} finally {
		会话.dispose();
		setTimeout(() => process.exit(0), 200);
	}
})();
