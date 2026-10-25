// 临时验证 preconnect 路径迁移：只调用纯函数，不启动 VS Code、不改用户设置。
'use strict';
const assert = require('assert');
const path = require('path');
const os = require('os');
const Module = require('module');
const 原加载 = Module._load;
const 桩 = require('./_vscode_stub_full.js');
Module._load = function (request, parent, isMain) {
	if (request === 'vscode') { return 桩; }
	return 原加载.call(this, request, parent, isMain);
};
const 扩展 = require('../接管远程服务器安装扩展/extension.js');
const t = 扩展._测试;
const 保存目录 = path.join(os.homedir(), 'AppData', 'Roaming', 'Code - Insiders', 'User', 'globalStorage', 'ebola-chan-bot.remotessh-server-installer');
const 旧路径 = 'c:\\Users\\张天夫\\AppData\\Roaming\\Code - Insiders\\User\\globalStorage\\ebola-chan-bot.remotessh-server-installer\\接管安装-上科大B服务器.ps1';
const 外部路径 = 'C:\\Users\\someone\\Documents\\my-preconnect.ps1';
const 便携 = t.生成钩子路径(保存目录, '上科大B服务器');
assert(便携.startsWith('~/'), '新钩子必须是 ~ 路径：' + 便携);
assert(!便携.includes('vhtmf'), '便携路径不得写入本机用户名');
assert.strictEqual(t.展开钩子路径(便携), path.join(保存目录, '接管安装-上科大B服务器.ps1'), '~ 必须展开回本机真实脚本');
assert.strictEqual(t.是我方脚本(旧路径, 保存目录), true, '旧机器生成的路径必须仍识别为本扩展脚本');
assert.strictEqual(t.是我方生成路径(旧路径, 保存目录), true, '历史 globalStorage 后缀必须识别');
assert.strictEqual(t.取外部原脚本({ '上科大B服务器': 旧路径 }, undefined, '上科大B服务器', 保存目录), '', '历史脚本不能触发外部脚本决策');
assert.strictEqual(t.取外部原脚本({ '上科大B服务器': 外部路径 }, undefined, '上科大B服务器', 保存目录), 外部路径, '真正的外部脚本必须保留并交用户决策');
const 新钩子 = t.重建钩子({ '上科大B服务器': 旧路径 }, {}, { '上科大B服务器': 便携 }, 保存目录);
assert.strictEqual(新钩子['上科大B服务器'], 便携, '旧路径必须被当前便携路径替换');
assert(!JSON.stringify(新钩子).includes('张天夫'), '迁移后不得残留旧用户名');
const 自调 = t.生成自调行(保存目录, '上科大B服务器');
assert(自调.includes('Join-Path $HOME'), '自调行也必须按 $HOME 定位');
assert(!自调.includes('vhtmf'), '自调行不得写死当前用户名');
console.log('路径迁移纯函数验证全部通过');
console.log('便携钩子=' + 便携);
console.log('自调行=' + 自调);
