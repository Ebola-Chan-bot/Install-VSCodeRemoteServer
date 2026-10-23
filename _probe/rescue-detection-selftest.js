// 终端超时检测的回归自检（纯 node，不需要 VS Code）
// 复刻 2026-10-22 线上事故：一次调试连出 6 个只含 cli.log 的 CLI 空壳会话目录，把真实会话挤到第 7 位，
// 旧口径「目录名倒序取前两个」只扫到空壳 → 18 次 Connecting with SSH timed out 全程没触发自动救援。
// 本自检用假造的 logs 目录树同时验证：新口径必扫到真实日志、旧口径必然失明（正向对照）、网络类报错不误判、hex 权威名也能匹配。
// 用法：node _probe/rescue-detection-selftest.js
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

let 失败 = 0;
function 断言(条件, 说明) {
	if (条件) { console.log('OK  ' + 说明); } else { console.log('FAIL ' + 说明); 失败++; }
}

const 临时根 = fs.mkdtempSync(path.join(os.tmpdir(), 'vsi-detect-'));
const logs根 = path.join(临时根, 'logs');
fs.mkdirSync(logs根, { recursive: true });

// 真实会话：window3 的 Remote-SSH 日志里有 3 次超时（含 hex 权威名），window4 是真实网络故障（必须排除，别误判成通道死）
const 真实会话 = '20261022T121929';
const 通道死目录 = path.join(logs根, 真实会话, 'window3', 'exthost', 'output_logging_20261022T142125');
fs.mkdirSync(通道死目录, { recursive: true });
const 主机名 = '上科大A服务器_张天夫';
const hex = Buffer.from(JSON.stringify({ hostName: 主机名 }), 'utf8').toString('hex');
fs.writeFileSync(path.join(通道死目录, '1-Remote - SSH.log'), [
	'[14:21:25.663] SSH Resolver called for "ssh-remote+' + hex + '", attempt 1',
	'[14:21:35.710] Terminal shell path: C:\\WINDOWS\\System32\\cmd.exe',
	'[14:22:07.714] Resolver error: Error: Connecting with SSH timed out',
	'[14:22:40.993] Exec server for ssh-remote+' + hex + ' failed: Error: Connecting with SSH timed out',
	'[14:23:13.035] Error opening exec server for ssh-remote+' + hex + ': Error: Connecting with SSH timed out',
	'',
].join('\n'));

const 网络故障目录 = path.join(logs根, 真实会话, 'window4', 'exthost', 'output_logging_20261022T143000');
fs.mkdirSync(网络故障目录, { recursive: true });
const 网络故障日志 = path.join(网络故障目录, '1-Remote - SSH.log');
fs.writeFileSync(网络故障日志, [
	'[14:30:00.000] SSH Resolver called for host: ' + 主机名,
	'[14:30:02.000] Resolver error: Error: Connecting with SSH timed out',
	'[14:30:05.000] Permission denied (publickey).',
	'[14:30:09.000] Resolver error: Error: Connecting with SSH timed out',
	'',
].join('\n'));
// 把「陈旧日志」的 mtime 推到 3 小时前：超出 20 分钟窗口，不该被当近期证据
const 陈旧时刻 = (Date.now() - 3 * 3600 * 1000) / 1000;
fs.utimesSync(网络故障日志, 陈旧时刻, 陈旧时刻);

// 6 个 CLI 空壳会话目录：目录名都比真实会话新（名字倒序排在前面），且只含 cli.log
for (const 空壳 of ['20261022T122042', '20261022T122126', '20261022T123919', '20261022T124519', '20261022T124553', '20261022T141045']) {
	const 目录 = path.join(logs根, 空壳);
	fs.mkdirSync(目录, { recursive: true });
	fs.writeFileSync(path.join(目录, 'cli.log'), 'CLI invocation only\n');
}

// require 前把 vscode 桩的 logUri 指进假 logs 树（扩展靠 logUri 反推 logs 根与本会话目录名）
const 桩 = require('./_vscode_stub_full.js');
桩.env.logUri = { fsPath: path.join(logs根, 真实会话, 'window3', 'exthost', 'ebola-chan-bot.remotessh-server-installer', 'x.log') };
桩.workspace.getConfiguration = () => ({ get: () => undefined });
const 原解析 = Module._resolveFilename;
Module._resolveFilename = function (request, ...args) {
	if (request === 'vscode') { return require.resolve('./_vscode_stub_full.js'); }
	return 原解析.call(this, request, ...args);
};
const 扩展 = require('../接管远程服务器安装扩展/extension.js');
const 测 = 扩展._测试;
断言(!!测, '扩展导出了 _测试 钩子（检测口径可回归）');

console.log('');
console.log('===== 新口径（必扫到真实日志，空壳挤不掉） =====');
const 本会话 = 测.找本会话目录名();
断言(本会话 === 真实会话, '本会话目录名由 logUri 反推得出（实测 ' + 本会话 + '）');
const 根 = 测.找logs根目录();
断言(根 === logs根, 'logs 根由 logUri 反推得出');

const 日志组 = 测.列近期RemoteSshLog();
断言(日志组.length === 1, '只收到近 20 分钟内改写的 Remote-SSH 日志（实测 ' + 日志组.length + ' 个，期望 1 = 陈旧的网络故障日志被时间窗排除）');
断言(日志组.length === 1 && 日志组[0].startsWith(通道死目录), '收到的正是 window3 那份超时日志');

console.log('');
console.log('===== 正向对照：旧口径「目录名倒序取前两个」在本场景必然失明 =====');
const 空壳数 = fs.readdirSync(logs根).filter(n => /^\d{8}T\d{6}$/.test(n)).sort().reverse().slice(0, 2);
断言(空壳数.every(n => !fs.existsSync(path.join(logs根, n, 'window3'))), '最新两个目录都是 CLI 空壳（无 window 子目录）——正是线上事故形态');
const 旧扫描 = [];
for (const 会 of 空壳数) {
	const w = path.join(logs根, 会);
	if (fs.existsSync(w)) { for (const x of fs.readdirSync(w)) { if (/^window\d+$/.test(x)) { 旧扫描.push(x); } } }
}
断言(旧扫描.length === 0, '旧口径扫不到任何窗口日志（实测 ' + 旧扫描.length + ' 个）= 检测彻底失明，这条自检能拦住同类回归');

console.log('');
console.log('===== 判定逻辑 =====');
const 命中 = 测.找近期安装超时日志([主机名], 日志组);
断言(!!命中, '同名主机 ≥2 次超时无网络报错 → 命中（触发自愈救援）');
断言(命中 && 命中.次数 === 3, '超时次数统计正确（实测 ' + (命中 ? 命中.次数 : 'null') + '，期望 3）');
断言(命中 && 命中.主机.length === 1 && 命中.主机[0] === 主机名, '命中主机名正确（hex 权威名也能匹配上）');
const 网络组 = 测.找近期安装超时日志([主机名], [网络故障日志]);
断言(!网络组, '有 Permission denied 等网络/凭据特征 → 不判定为通道死亡（避免误自愈误逃逸）');
const 空命中 = 测.找近期安装超时日志([主机名], []);
断言(!空命中, '没扫到日志时不误报');
const 陌生主机 = 测.找近期安装超时日志(['别的主机'], 日志组);
断言(!陌生主机, '名单里没有的主机不触发（不会误伤别的连接）');

// 收尾：删掉假造的 logs 树
fs.rmSync(临时根, { recursive: true, force: true });
断言(!fs.existsSync(临时根), '临时 logs 树已清理');

console.log('');
console.log('检测回归自检断言失败数: ' + 失败);
process.exit(失败 === 0 ? 0 : 1);
