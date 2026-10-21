// 快速体检：目标窗口 renderer 是否仍响应（Runtime.evaluate 3 秒内回 = 活着）。
'use strict';
const http = require('http');
const PORT = Number(process.argv[2] || 17890);
const MATCH = process.argv[3] || '上科大B服务器';
function getList() { return new Promise((res, rej) => { const r = http.get({ host: '127.0.0.1', port: PORT, path: '/json/list' }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } }); }); r.on('error', rej); r.setTimeout(4000, () => r.destroy(new Error('超时'))); }); }
(async () => {
	const list = await getList();
	const t = list.filter(x => x.type === 'page').find(p => (p.title || '').includes(MATCH));
	if (!t) { console.log('窗口不存在'); process.exit(1); }
	const ws = new WebSocket(t.webSocketDebuggerUrl);
	const to = setTimeout(() => { console.log('!! 3 秒无响应：renderer 可能仍被暂停或已死'); process.exit(3); }, 3000);
	ws.addEventListener('open', () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: 'JSON.stringify({alive:true,probeDone:!!globalThis.__tsProbeDone,paletteOpen:(function(){try{var q=document.querySelector(".quick-input-widget");return !!q&&(q.style.visibility!=="hidden"&&getComputedStyle(q).display!=="none")}catch(e){return "err"}})(),title:document.title.slice(0,60)})', returnByValue: true } })));
	ws.addEventListener('message', ev => { const m = JSON.parse(ev.data); if (m.id === 1) { clearTimeout(to); console.log('响应:', JSON.stringify(m.result && m.result.result && m.result.result.value)); process.exit(0); } });
	ws.addEventListener('error', e => { clearTimeout(to); console.log('WS 错误'); process.exit(2); });
})();
