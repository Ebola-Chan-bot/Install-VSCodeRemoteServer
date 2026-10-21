// CDP（Chrome DevTools Protocol）客户端：扩展宿主内直连 argv.json 开启的 remote-debugging-port，附着本窗口 renderer 做诊断与修复。
//
// 为什么扩展 API 不够：窗口终端通道死亡（renderer ↔ pty host 的绑定坏在窗口进程内部）时，扩展宿主仍活着（preconnect 照常成功），但扩展 API 摸不到 renderer 的 DI 容器——`window.createTerminal` 只会跟着一起挂。要读取/修复窗口内部状态必须进入 renderer 的 JS 堆，途径 = Electron CDP 调试端口 + Debugger 断点帧内求值（与本机「Copilot Chat 注入器」扩展同一手法，minWebSocket/CDP 会话实现亦移植自它，零第三方依赖）。
//
// 端口来源：argv.json 的 "remote-debugging-port"（官方 SUPPORTED_ELECTRON_SWITCHES 白名单键，字符串值）。本机已由 Chat 注入器写入 17890；本扩展只读取与探活，不负责写入引导（避免两个扩展重复写同一文件；端口不在线时 L2 诊断自动跳过，其余救援层级不受影响）。
//
// 多窗口共端口：/json/list 列出全部窗口 target，必须按本窗口特征复核标题后才附着，绝不误attach别的窗口（注入器实测坑）。
'use strict';

const net = require('net');
const tls = require('tls');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const { EventEmitter } = require('events');

// ===================== 极简 RFC6455 WebSocket 客户端（移植自 Chat 注入器 minWebSocket.ts） =====================

class WebSocket最小客户端 extends EventEmitter {
	constructor(选项) {
		super();
		this.选项 = 选项;
		this._状态 = 'connecting';
		this.socket = undefined;
		this.接收缓冲 = Buffer.alloc(0);
		this.分片缓冲 = [];
		this.分片总长 = 0;
		this.分片opcode = -1;
		this.关码 = undefined;
		this.maxMessageBytes = 选项.maxMessageBytes ?? 64 * 1024 * 1024;
		this.心跳定时器 = undefined;
		queueMicrotask(() => this.发起连接().catch(err => this.进入关闭(err instanceof Error ? err : new Error(String(err)))));
	}

	get 状态() { return this._状态; }

	send(data) {
		if (this.状态 !== 'open') { throw new Error(`WebSocket 未打开（当前 ${this.状态}）`); }
		this.写帧(true, 0x1, Buffer.from(data, 'utf8'));
	}

	close(code = 1000, reason = '') {
		if (this.状态 === 'closed' || this.状态 === 'closing') { return; }
		this._状态 = 'closing';
		try {
			const 原因缓冲 = Buffer.from(reason, 'utf8');
			const 载荷 = Buffer.alloc(2 + 原因缓冲.length);
			载荷.writeUInt16BE(code, 0);
			原因缓冲.copy(载荷, 2);
			this.写帧(true, 0x8, 载荷);
		} catch { /* 关闭路径上的写失败直接拆套接字即可 */ }
		try { this.socket?.end(); } catch { /* 忽略 */ }
	}

	async 发起连接() {
		const url = new URL(this.选项.url);
		const 端口 = url.port ? Number(url.port) : (url.protocol === 'wss:' ? 443 : 80);
		const key = crypto.randomBytes(16).toString('base64');
		const 期望accept = crypto.createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');

		const socket = url.protocol === 'wss:'
			? tls.connect({ host: url.hostname, port: 端口, servername: url.hostname })
			: net.connect({ host: url.hostname, port: 端口 });
		this.socket = socket;

		await new Promise((resolve, reject) => {
			const 超时 = setTimeout(() => reject(new Error('WebSocket 握手超时')), this.选项.handshakeTimeoutMs ?? 5000);
			const 路径 = url.pathname + (url.search ?? '');
			const 头列表 = [
				`GET ${路径} HTTP/1.1`,
				`Host: ${url.hostname}:${端口}`,
				'Upgrade: websocket',
				'Connection: Upgrade',
				`Sec-WebSocket-Key: ${key}`,
				'Sec-WebSocket-Version: 13',
			];
			for (const [k, v] of Object.entries(this.选项.headers ?? {})) { 头列表.push(`${k}: ${v}`); }
			socket.once('error', err => { clearTimeout(超时); reject(err); });
			socket.write(头列表.join('\r\n') + '\r\n\r\n');

			const 握手数据 = [];
			const onData = (chunk) => {
				握手数据.push(chunk);
				const 拼接 = Buffer.concat(握手数据);
				const 边界 = 拼接.indexOf('\r\n\r\n');
				if (边界 < 0) {
					if (拼接.length > 64 * 1024) { clearTimeout(超时); socket.destroy(); reject(new Error('握手响应头过大')); }
					return;
				}
				socket.removeListener('data', onData);
				clearTimeout(超时);
				const 头文本 = 拼接.subarray(0, 边界).toString('utf8');
				const 首行 = 头文本.split('\r\n')[0];
				if (!/101/.test(首行)) { reject(new Error(`WebSocket 握手被拒绝: ${首行}`)); return; }
				const accept匹配 = 头文本.match(/sec-websocket-accept:\s*(\S+)/i);
				if (!accept匹配 || accept匹配[1] !== 期望accept) { reject(new Error('WebSocket 握手 accept 校验失败')); return; }
				const 余下 = 拼接.subarray(边界 + 4);
				if (余下.length > 0) { this.接收缓冲 = 余下; this.处理接收缓冲(); }
				resolve();
			};
			socket.on('data', onData);
		});

		this._状态 = 'open';
		socket.on('data', chunk => { this.接收缓冲 = Buffer.concat([this.接收缓冲, chunk]); this.处理接收缓冲(); });
		socket.on('close', () => this.进入关闭(this.关码 !== undefined ? undefined : new Error('连接被对端关闭')));
		socket.on('error', err => this.进入关闭(err));

		// CDP 链路空闲时保活：每 20 秒 ping 一次（Electron 内置 CDP server 按协议回 pong）
		this.心跳定时器 = setInterval(() => {
			if (this.状态 === 'open') { try { this.写帧(true, 0x9, Buffer.alloc(0)); } catch { /* 关闭竞态忽略 */ } }
		}, 20000);
		this.emit('open');
	}

	处理接收缓冲() {
		while (true) {
			const 帧 = this.解析帧头(this.接收缓冲);
			if (!帧) { return; }
			const 掩码起 = 帧.headerLength;
			const 载荷起 = 掩码起 + (帧.masked ? 4 : 0);
			const 帧总长 = 载荷起 + 帧.payloadLength;
			if (this.接收缓冲.length < 帧总长) { return; } // 半帧，等更多数据
			let 载荷 = this.接收缓冲.subarray(载荷起, 帧总长);
			if (帧.masked) {
				const 掩码 = this.接收缓冲.subarray(掩码起, 掩码起 + 4);
				载荷 = Buffer.from(载荷);
				for (let i = 0; i < 载荷.length; i++) { 载荷[i] ^= 掩码[i % 4]; }
			}
			this.接收缓冲 = this.接收缓冲.subarray(帧总长);
			this.处理帧(帧, 载荷);
		}
	}

	处理帧(帧, 载荷) {
		switch (帧.opcode) {
			case 0x0: case 0x1: case 0x2: this.追加数据帧(帧, 载荷); break;
			case 0x8:
				this.关码 = 载荷.length >= 2 ? 载荷.readUInt16BE(0) : 1005;
				this._状态 = 'closing';
				try { this.socket?.end(); } catch { /* 忽略 */ }
				this.进入关闭();
				break;
			case 0x9: if (this.状态 === 'open') { try { this.写帧(true, 0xA, 载荷); } catch { /* 竞态忽略 */ } } break;
			case 0xA: break;
			default: this.进入关闭(new Error(`未知 WebSocket opcode ${帧.opcode}`)); break;
		}
	}

	追加数据帧(帧, 载荷) {
		const 首帧 = 帧.opcode !== 0x0;
		if (首帧) { this.分片缓冲 = [载荷]; this.分片总长 = 载荷.length; this.分片opcode = 帧.opcode; }
		else { this.分片缓冲.push(载荷); this.分片总长 += 载荷.length; }
		if (this.分片总长 > this.maxMessageBytes) { this.进入关闭(new Error(`WebSocket 消息超过大小上限 ${this.maxMessageBytes}`)); return; }
		if (!帧.fin) { return; }
		const 完整 = this.分片缓冲.length === 1 ? this.分片缓冲[0] : Buffer.concat(this.分片缓冲);
		this.分片缓冲 = []; this.分片总长 = 0;
		this.emit('message', 完整.toString(this.分片opcode === 0x1 ? 'utf8' : 'latin1'));
		this.分片opcode = -1;
	}

	解析帧头(buf) {
		if (buf.length < 2) { return undefined; }
		const b0 = buf[0]; const b1 = buf[1];
		const fin = (b0 & 0x80) !== 0;
		const opcode = b0 & 0x0F;
		const masked = (b1 & 0x80) !== 0;
		let payloadLength = b1 & 0x7F;
		let 偏移 = 2;
		if (payloadLength === 126) {
			if (buf.length < 偏移 + 2) { return undefined; }
			payloadLength = buf.readUInt16BE(偏移); 偏移 += 2;
		} else if (payloadLength === 127) {
			if (buf.length < 偏移 + 8) { return undefined; }
			const 高32 = buf.readUInt32BE(偏移); const 低32 = buf.readUInt32BE(偏移 + 4);
			if (高32 > 0) { this.进入关闭(new Error('不支持超过 4GB 的 WebSocket 帧')); return undefined; }
			payloadLength = 低32; 偏移 += 8;
		}
		if (payloadLength > this.maxMessageBytes) { this.进入关闭(new Error(`WebSocket 帧超过大小上限 ${payloadLength}`)); return undefined; }
		return { fin, opcode, masked, payloadLength, headerLength: 偏移 };
	}

	写帧(fin, opcode, 载荷) {
		const 掩码 = crypto.randomBytes(4);
		const 需长度位 = 载荷.length < 126 ? 0 : (载荷.length < 65536 ? 2 : 8);
		const 帧头长 = 2 + 需长度位 + 4; // 基础头 + 扩展长度 + 掩码键（客户端帧必须掩码）
		const 帧 = Buffer.alloc(帧头长 + 载荷.length);
		帧[0] = (fin ? 0x80 : 0x00) | opcode;
		帧[1] = 0x80 | (需长度位 === 0 ? 载荷.length : (需长度位 === 2 ? 126 : 127));
		if (需长度位 === 2) { 帧.writeUInt16BE(载荷.length, 2); }
		else if (需长度位 === 8) { 帧.writeUInt32BE(0, 2); 帧.writeUInt32BE(载荷.length, 6); }
		掩码.copy(帧, 帧头长 - 4);
		for (let i = 0; i < 载荷.length; i++) { 帧[帧头长 + i] = 载荷[i] ^ 掩码[i % 4]; }
		try { this.socket?.write(帧); } catch { /* 关闭竞态忽略 */ }
	}

	进入关闭(err) {
		if (this._状态 === 'closed') { return; }
		this._状态 = 'closed';
		if (this.心跳定时器) { clearInterval(this.心跳定时器); this.心跳定时器 = undefined; }
		try { this.socket?.destroy(); } catch { /* 忽略 */ }
		if (err) { this.emit('error', err); }
		this.emit('close', this.关码);
	}
}

// ===================== CDP 会话与客户端 =====================

/** 单个 target 的 CDP 会话：id 递增的 request/response 配对 + 事件分发，每个请求都带超时（防渲染器被暂停时响应悬挂拖死救援流程）。 */
class CDP会话 {
	constructor(目标, wsUrl) {
		this.目标 = 目标;
		this.ws = new WebSocket最小客户端({ url: wsUrl });
		this.下一Id = 1;
		this.pending = new Map();
		this.事件监听 = new Map();
		this.已关闭 = false;
		this.on关闭Emitter = new EventEmitter();
		this.关闭事件 = (h) => { this.on关闭Emitter.on('close', h); return () => this.on关闭Emitter.removeListener('close', h); };
		this.ws.on('message', text => this.处理消息(text));
		this.ws.on('error', () => { /* 错误最终表现为 close，统一走关闭路径 */ });
		this.ws.on('close', () => this.进入关闭());
	}

	get 已就绪() { return this.ws.状态 === 'open' && !this.已关闭; }

	async 等待就绪(超时Ms = 5000) {
		if (this.ws.状态 === 'open') { return; }
		if (this.ws.状态 === 'closed') { throw new Error('CDP WebSocket 已关闭'); }
		await new Promise((resolve, reject) => {
			const 超时 = setTimeout(() => reject(new Error('CDP WebSocket 连接超时')), 超时Ms);
			this.ws.once('open', () => { clearTimeout(超时); resolve(); });
			this.ws.once('close', () => { clearTimeout(超时); reject(new Error('CDP WebSocket 连接中断')); });
		});
	}

	send(method, params, 超时Ms = 10000) {
		if (!this.已就绪) { return Promise.reject(new Error('CDP 会话未连接')); }
		const id = this.下一Id++;
		return new Promise((resolve, reject) => {
			const 超时 = setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`CDP ${method} 响应超时(${超时Ms}ms)`)); } }, 超时Ms);
			this.pending.set(id, { resolve, reject });
			try { this.ws.send(JSON.stringify({ id, method, params })); }
			catch (e) { clearTimeout(超时); this.pending.delete(id); reject(e instanceof Error ? e : new Error(String(e))); }
		});
	}

	on事件(事件名, 处理) {
		const 列表 = this.事件监听.get(事件名) ?? [];
		列表.push(处理);
		this.事件监听.set(事件名, 列表);
		return () => {
			const 当前 = this.事件监听.get(事件名);
			if (当前) { const idx = 当前.indexOf(处理); if (idx >= 0) { 当前.splice(idx, 1); } }
		};
	}

	处理消息(text) {
		let 消息;
		try { 消息 = JSON.parse(text); } catch { return; }
		if (消息.id !== undefined) {
			const p = this.pending.get(消息.id);
			if (p) { this.pending.delete(消息.id); if (消息.error) { p.reject(new Error(`CDP 错误: ${消息.error.message ?? 'unknown'}`)); } else { p.resolve(消息.result); } }
			return;
		}
		if (消息.method) {
			for (const 处理 of (this.事件监听.get(消息.method) ?? []).slice()) {
				try { 处理(消息.params); } catch { /* 事件处理器异常不得拖垮会话 */ }
			}
		}
	}

	进入关闭() {
		if (this.已关闭) { return; }
		this.已关闭 = true;
		for (const [, p] of this.pending) { p.reject(new Error('CDP 会话已关闭')); }
		this.pending.clear();
		this.on关闭Emitter.emit('close');
	}

	dispose() {
		this.进入关闭();
		try { this.ws.close(); } catch { /* 忽略 */ }
	}
}

/** TCP 探测调试端口是否在监听（区分「argv.json 已写但主进程未重启」与「端口正常」）。 */
function 探测调试端口(端口, 超时Ms = 1500) {
	return new Promise(resolve => {
		const sock = net.connect({ host: '127.0.0.1', port: 端口 });
		let 已决 = false;
		const 完成 = 结果 => { if (已决) { return; } 已决 = true; clearTimeout(计时); sock.destroy(); resolve(结果); };
		const 计时 = setTimeout(() => 完成(false), 超时Ms);
		sock.once('connect', () => 完成(true));
		sock.once('error', () => 完成(false));
	});
}

/** GET /json/list 拉取全部 target；端口未开返回 undefined（不抛异常）。workbench 页面排前。 */
async function 发现目标(端口) {
	try {
		const 内容 = await new Promise((resolve, reject) => {
			const req = http.get({ host: '127.0.0.1', port: 端口, path: '/json/list' }, res => {
				let buf = ''; res.on('data', d => buf += d);
				res.on('end', () => resolve(buf));
			});
			req.on('error', reject);
			req.setTimeout(3000, () => req.destroy(new Error('发现目标超时')));
		});
		const json = JSON.parse(内容);
		const pages = json.filter(t => t.type === 'page');
		const 是工作台 = t => /workbench/i.test(`${t.url ?? ''} ${t.title ?? ''}`);
		return [...pages.filter(是工作台), ...pages.filter(t => !是工作台(t))];
	} catch { return undefined; }
}

// ===================== argv.json 调试端口读取（只读，不写入引导） =====================

/** 按 process.execPath 推断渠道解析用户 argv.json 路径（与 Chat 注入器同逻辑）。 */
function 解析argv路径() {
	const 家目录 = os.homedir();
	let 首选渠道;
	try {
		const 可执行路径 = process.execPath.toLowerCase();
		首选渠道 = 可执行路径.includes('insiders') ? '.vscode-insiders'
			: (可执行路径.includes('code - oss') || 可执行路径.includes('codeoss')) ? '.vscode-oss' : '.vscode';
	} catch { 首选渠道 = '.vscode'; }
	const 候选 = [首选渠道, '.vscode', '.vscode-insiders', '.vscode-oss'].filter((v, i, a) => a.indexOf(v) === i);
	for (const 目录 of 候选) {
		const 根 = path.join(家目录, 目录);
		if (fs.existsSync(根)) { return path.join(根, 'argv.json'); }
	}
	return path.join(家目录, 首选渠道, 'argv.json');
}

/** 读 argv.json 里的 remote-debugging-port（字符串与数字形式都认；数字形式会被 main.js 静默忽略，如实标注）。 */
function 读取调试端口(argvPath) {
	try {
		const 原文 = fs.readFileSync(argvPath, 'utf8');
		const 匹配 = 原文.match(/"remote-debugging-port"\s*:\s*(?:"(\d+)"|(\d+))/);
		if (匹配) { return { 已有: true, 端口: Number(匹配[1] ?? 匹配[2]), 为字符串形式: 匹配[1] !== undefined }; }
		return { 已有: false };
	} catch { return { 已有: false }; }
}

module.exports = {
	WebSocket最小客户端,
	CDP会话,
	探测调试端口,
	发现目标,
	解析argv路径,
	读取调试端口,
};
