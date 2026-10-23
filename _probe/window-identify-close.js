// 窗口身份判别与小窗口清理 harness：用 CDP 读各窗口工作台的可见文本，找出「authority 解码失败、被当成主机名在解析」的窗口并关掉。
// 背景：手写 ssh-remote authority 的 hex 时打错一个字符（host→hosw），Remote-SSH 解不出 hostName 就把整串 hex 当主机名连（必然失败），
// 这类窗口标题仍是空白的「Visual Studio Code - Insiders」，肉眼无法与正在正常连接的新窗口区分，故按可见文本判别后再关。
// 用法：node window-identify-close.js <端口> [--close]
'use strict';
const pathMod = require('path');
const http = require('http');
const cdp = require('../接管远程服务器安装扩展/cdp.js');

const 端口 = Number(process.argv[2] || 17890);
const 要关闭 = process.argv.indexOf('--close') >= 0;
// 打错的 hex 前缀（{"hoswName": 的十六进制）与正确主机名（判别用，二者都不含反引号/元字符）
const 错误hex = '7b22686f73774e616d65';
const 正确主机名 = '上科大A服务器_张天夫';
const 表达式 = '(function(){try{var 文=(document.body?document.body.innerText:"");'
	+ 'return {title:document.title,含错误hex:文.indexOf("' + 错误hex + '")>=0,含主机名:文.indexOf("' + 正确主机名 + '")>=0,字符数:文.length};}'
	+ 'catch(e){return {err:String(e)};}})()';

function 关闭目标(目标id) {
	return new Promise(resolve => {
		const req = http.get({ host: '127.0.0.1', port: 端口, path: '/json/close/' + 目标id }, res => {
			let buf = ''; res.on('data', d => buf += d); res.on('end', () => resolve(buf.trim()));
		});
		req.on('error', e => resolve('关闭失败:' + e.message));
		req.setTimeout(5000, () => { req.destroy(new Error('关闭超时')); });
	});
}

(async () => {
	const targets = await cdp.发现目标(端口);
	if (!targets) { console.log('调试端口未在线'); process.exit(1); }
	console.log('端口 ' + 端口 + ' 下 page 目标数: ' + targets.length);
	for (const t of targets) {
		const 会话 = new cdp.CDP会话(t, t.webSocketDebuggerUrl);
		let 值 = null;
		try {
			await 会话.等待就绪(6000);
			await 会话.send('Runtime.enable', {}, 6000);
			const ev = await 会话.send('Runtime.evaluate', { expression: 表达式, returnByValue: true }, 8000);
			值 = ev && ev.result && ev.result.value;
		} catch (e) {
			值 = { err: String((e && e.message) || e) };
		} finally {
			try { 会话.dispose(); } catch { }
		}
		const 是错的 = !!(值 && 值.含错误hex);
		console.log('--- id=' + t.id + (是错的 ? '  ← 打错的 hex 窗口（应关闭）' : ''));
		console.log('    title=' + String((值 && 值.title) || t.title || '').slice(0, 90));
		console.log('    ' + JSON.stringify(值));
		if (是错的 && 要关闭) { console.log('    关闭结果: ' + (await 关闭目标(t.id))); }
	}
	process.exit(0);
})();
