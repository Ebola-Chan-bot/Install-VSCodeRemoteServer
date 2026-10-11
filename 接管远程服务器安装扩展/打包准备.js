// 打包前准备（vsce 的 vscode:prepublish 钩子）：把工作区模块原样复制进扩展的 module 目录。
// 模块源文件名即 VSIX 内文件名（一律 ASCII），不做任何改名与引用改写——改名后的脚本就是独立源码。
// 扩展入口按 <扩展>/../安装-VSCode远程服务/ 优先找模块、再按 <扩展>/module/ 兜底；打出来的 VSIX 装到
// 扩展目录后前者必然不存在，故必须把模块一并打包进 module 目录，否则市场安装的扩展找不到模块无法工作。
'use strict';

const fs = require('fs');
const path = require('path');

const 扩展根 = __dirname;
const 模块源 = path.join(扩展根, '..', '安装-VSCode远程服务');
const 模块目标 = path.join(扩展根, 'module');

if (!fs.existsSync(path.join(模块源, 'Install-VSCodeRemoteServer.psd1'))) {
	throw new Error('未找到模块源目录：' + 模块源);
}

fs.rmSync(模块目标, { recursive: true, force: true });
fs.cpSync(模块源, 模块目标, { recursive: true });
console.log('已把模块复制进打包目录：' + 模块目标);
