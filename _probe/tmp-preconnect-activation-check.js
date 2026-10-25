// 临时验证真实 activate：旧机器路径在首次对齐时迁移，且 activate 的 Promise 等到写入完成。
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const Module = require('module');
const 扩展目录 = path.resolve(__dirname, '../接管远程服务器安装扩展');
const 测试根目录 = path.join(os.homedir(), 'AppData', 'Local', 'Temp', 'vsi-preconnect-activation-' + process.pid);
const 保存目录 = path.join(测试根目录, 'globalStorage', 'ebola-chan-bot.remotessh-server-installer');
const 旧路径 = 'c:\\Users\\张天夫\\AppData\\Roaming\\Code - Insiders\\User\\globalStorage\\ebola-chan-bot.remotessh-server-installer\\接管安装-上科大B服务器.ps1';
const 状态 = new Map();
const 配置 = {
	preconnect: { '上科大B服务器': 旧路径 },
	接管: ['上科大B服务器'],
	保活: []
};
let 警告 = [];
let 更新完成 = false;
const 配置对象 = section => ({
	get(key, 默认值) {
		if (section === '安装VSCode远程服务') {
			if (key === '接管的主机') return 配置.接管;
			if (key === '启用保活的主机') return 配置.保活;
		}
		if (section === 'remote.SSH' && key === 'remotePlatform') return {};
		return 默认值;
	},
	inspect(key) { return key === 'remote.SSH.preconnect' ? { globalValue: 配置.preconnect } : undefined; },
	async update(key, value) {
		if (key === 'remote.SSH.preconnect') { 配置.preconnect = value; 更新完成 = true; }
		else if (key === '接管的主机') 配置.接管 = value;
		else if (key === '启用保活的主机') 配置.保活 = value;
	}
});
const 桩 = {
	workspace: {
		onDidChangeConfiguration: () => ({ dispose() {} }),
		getConfiguration: 配置对象
	},
	commands: { registerCommand: () => ({ dispose() {} }) },
	extensions: { getExtension: id => id === 'ms-vscode-remote.remote-ssh' ? {} : undefined },
	window: {
		showWarningMessage: (...args) => { 警告.push(args); return Promise.resolve(undefined); },
		showInformationMessage: () => Promise.resolve(undefined),
		showErrorMessage: (...args) => { 警告.push(args); return Promise.resolve(undefined); },
		createOutputChannel: () => ({ appendLine() {}, show() {}, dispose() {} })
	},
	env: { appName: '路径测试', logUri: undefined, clipboard: { writeText: async () => {} } },
	ConfigurationTarget: { Global: 1 }
};
const 原加载 = Module._load;
Module._load = function (request, parent, isMain) { return request === 'vscode' ? 桩 : 原加载.call(this, request, parent, isMain); };
const 扩展 = require(扩展目录 + '/extension.js');
const context = {
	extensionPath: 扩展目录,
	globalStorageUri: { fsPath: 保存目录 },
	globalState: {
		get: (key, 默认值) => 状态.has(key) ? 状态.get(key) : 默认值,
		update: async (key, value) => { if (value === undefined) 状态.delete(key); else 状态.set(key, value); }
	},
	subscriptions: []
};
(async () => {
	try {
		await 扩展.activate(context);
		const 钩子 = 配置.preconnect['上科大B服务器'];
		assert(更新完成, 'activate 返回前必须完成钩子写入');
		assert(钩子 && 钩子.startsWith('~/'), '旧绝对路径必须迁移为便携路径：' + 钩子);
		assert(!钩子.includes('张天夫'), '不得保留旧机器用户名');
		const 实际文件 = path.join(保存目录, '接管安装-上科大B服务器.ps1');
		assert(fs.existsSync(实际文件), 'activate 返回时薄脚本必须已经存在');
		assert(fs.existsSync(path.join(保存目录, '接管安装实现.ps1')), '公共实现必须已部署');
		assert.strictEqual(警告.length, 0, '历史本扩展脚本不能弹外部脚本决策或错误：' + JSON.stringify(警告));
		console.log('activate 迁移验证通过：' + 钩子);
	} finally {
		for (const 项 of context.subscriptions) { if (项 && typeof 项.dispose === 'function') 项.dispose(); }
		fs.rmSync(测试根目录, { recursive: true, force: true });
	}
})().catch(e => { console.error(e.stack || e); process.exitCode = 1; });
