// bundle 源码定位器：从 workbench.desktop.main.js 里按正则切出上下文窗口，用来读混淆后的真实机制
// （本轮就是靠它搞清 whenConnected / connectionState / _initPrimaryBackend 的实际实现，避免凭记忆猜字段名）
// 用法：node _probe/bundle-grep.js <正则> [前后字符数] [最多命中数]
'use strict';
const fs = require('fs');
const path = require('path');
const appRoot = path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Microsoft VS Code Insiders', '76fae85ac1');
const bundle = path.join(appRoot, 'resources', 'app', 'out', 'vs', 'workbench', 'workbench.desktop.main.js');
if (!fs.existsSync(bundle)) {
	// 兜底：扫版本目录，取最新的那个
	const root = path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Microsoft VS Code Insiders');
	const 目录 = fs.readdirSync(root).filter(n => /^[0-9a-f]{10}$/.test(n));
	if (!目录.length) { console.log('找不到版本目录'); process.exit(1); }
	目录.sort((a, b) => fs.statSync(path.join(root, b)).mtimeMs - fs.statSync(path.join(root, a)).mtimeMs);
	for (const d of 目录) {
		const p = path.join(root, d, 'resources', 'app', 'out', 'vs', 'workbench', 'workbench.desktop.main.js');
		if (fs.existsSync(p)) { console.log('使用 bundle: ' + p); run(p); process.exit(0); }
	}
	console.log('找不到 bundle'); process.exit(1);
}
run(bundle);

function run(文件路径) {
	const 模式 = process.argv[2];
	const 窗 = Number(process.argv[3] || 420);
	const 上限 = Number(process.argv[4] || 6);
	if (!模式) { console.log('用法: node bundle-grep.js <正则> [前后字符数] [最多命中数]'); process.exit(1); }
	const src = fs.readFileSync(文件路径, 'utf8');
	console.log('bundle: ' + 文件路径 + '（' + src.length + ' 字符）');
	const re = new RegExp(模式, 'g');
	let m, n = 0;
	while ((m = re.exec(src)) !== null && n < 上限) {
		n++;
		const 起 = Math.max(0, m.index - 窗);
		const 止 = Math.min(src.length, m.index + m[0].length + 窗);
		const 行 = (src.slice(0, m.index).match(/\n/g) || []).length;
		const 片段 = src.slice(起, 止).replace(/\s*\n\s*/g, ' ');
		console.log('\n--- 命中 ' + n + '  偏移 ' + m.index + '  约在第 ' + 行 + ' 行  「' + m[0] + '」');
		console.log(片段);
	}
	console.log('\n命中总数（已打印 ' + n + ' 个）');
	let 总 = 0; re.lastIndex = 0;
	while (re.exec(src) !== null) { 总++; }
	console.log('  ' + 总);
}
