// 载荷载入单元自检：验证 取渲染器脚本 的占位符替换、残留校验、语法可解析性（不连 CDP、不碰窗口）。
// 用法：node payload-load-check.js
'use strict';
const fs = require('fs');
const pathMod = require('path');
const Module = require('module');

// vscode 模块桩：见同目录 _vscode_stub_full.js（完整语法版，terminalRescue.js require 期所需的最小 API 面）
const 桩路径 = pathMod.join(__dirname, '_vscode_stub_full.js');
const 原解析 = Module._resolveFilename;
Module._resolveFilename = function (request, ...args) {
	if (request === 'vscode') { return 桩路径; }
	return 原解析.call(this, request, ...args);
};

const 救援 = require('../接管远程服务器安装扩展/terminalRescue.js');
const 文件表 = { '脚本_钥匙': 'key-handover.js', '脚本_诊断': 'channel-diagnose.js', '脚本_修复': 'channel-repair.js' };
let 失败 = 0;
for (const [导出名, 文件] of Object.entries(文件表)) {
	const 文 = 救援[导出名];
	const 检查 = [];
	// ① 非空
	检查.push([文 && 文.trim().length > 200, '长度 ' + (文 ? 文.length : 0)]);
	// ② 占位符已替换：不得残留 __中文__；且宿主注入值确实出现在文中
	const 残留 = /__[\u4e00-\u9fa5][\u4e00-\u9fa5A-Za-z0-9]*__/.exec(文);
	检查.push([!残留, '占位符残留: ' + (残留 ? 残留[0] : '无')]);
	检查.push([文.includes(救援.钥匙前缀), '含钥匙前缀 ' + 救援.钥匙前缀]);
	检查.push([!文.includes('${'), '无未展开的 ${} 模板插值']);
	// ③ 语法可解析（作为表达式）——真正决定能否被 evaluateOnCallFrame/Runtime.evaluate 吃下
	let 解析结果 = 'OK';
	try { new Function('return (' + 文 + ')'); } catch (e) { 解析结果 = 'SyntaxError: ' + e.message; }
	检查.push([解析结果 === 'OK', 解析结果]);
	// ④ 载入幂等（缓存生效，两次同一对象）
	检查.push([救援.取渲染器脚本(文件) === 文, '缓存幂等']);
	const 全过 = 检查.every(c => c[0]);
	if (!全过) { 失败++; }
	console.log((全过 ? '✓ ' : '✗ ') + 导出名 + ' (' + 文件 + ', ' + 文.length + ' 字)');
	for (const [过, 描述] of 检查) { if (!过 || 描述.includes('SyntaxError') || 描述.startsWith('占位符')) { console.log('    ' + (过 ? '· ' : '! ') + 描述); } }
}
// ⑤ 竞速占位符替换成真数字（3000 应出现，诊断竞速Ms 值）
const 诊断文 = 救援.脚本_诊断;
console.log((诊断文.includes(',3000)') || 诊断文.includes(',3000,') ? '✓ ' : '✗ ') + '诊断竞速占位符已替换为数值 3000');

// ⑥ 反向测试：守卫必须真的会拦（这两项是「坏载荷不会被静默送进窗口」的唯一保障）
const 载荷目录 = pathMod.join(__dirname, '..', '接管远程服务器安装扩展', 'renderer-scripts');
// 6a 文件缺失 → 抛错并带上完整路径
try { 救援.取渲染器脚本('no-such-payload.js'); console.log('✗ 载荷缺失未报错（守卫失效）'); 失败++; }
catch (e) { const 过 = /渲染器载荷读取失败/.test(e.message) && e.message.includes('no-such-payload.js'); console.log((过 ? '✓ ' : '✗ ') + '载荷缺失抛错: ' + e.message.slice(0, 100)); if (!过) { 失败++; } }
// 6b 残留占位符 → 抛错并点名那个占位符（临时造一个带未知占位符的载荷，测完立即删）
const 坏载荷 = pathMod.join(载荷目录, '__selftest-bogus.js');
try {
	fs.writeFileSync(坏载荷, '(function(){ return { 值: __未知占位__ }; })()\n', 'utf8');
	try { 救援.取渲染器脚本('__selftest-bogus.js'); console.log('✗ 占位符残留未被拦下（守卫失效）'); 失败++; }
	catch (e) { const 过 = /仍残留占位符 __未知占位__/.test(e.message); console.log((过 ? '✓ ' : '✗ ') + '占位符残留抛错: ' + e.message.slice(0, 100)); if (!过) { 失败++; } }
} finally { try { fs.unlinkSync(坏载荷); } catch { /* 清理失败不致命 */ } }
console.log('反向测试残留文件已清理: ' + (!fs.existsSync(坏载荷)));

process.exit(失败 ? 1 : 0);
