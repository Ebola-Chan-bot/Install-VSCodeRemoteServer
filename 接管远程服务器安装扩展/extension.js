// 接管远程服务器安装 扩展入口：把 Install-VSCodeRemoteServer 模块接入 Remote-SSH 的远程服务器安装步骤。
// 唯一开关：设置项「安装VSCode远程服务.接管远程服务器安装」。
// 开启：Remote-SSH 每次连接前先由本模块安装远程服务器（竞速供给 + 旧 glibc 自动部署官方 sysroot + CLI 引导预装），Remote-SSH 自带的安装步骤检测到服务端已就位便直接复用——即「用本模块的方式替换原本的远程服务器安装」。
// 关闭：撤下钩子并把 remote.SSH.preconnect 还原为接管前的取值——即「还原」。
//
// 机制依据（Remote-SSH 0.128 源码实测）：remote.SSH.preconnect 取字符串时对全部主机生效、取对象时按主机映射，脚本在 Windows 上必须是 .ps1，以 powershell.exe -NoProfile -ExecutionPolicy Bypass -File 调用且不带任何参数，非零退出会直接中止连接。故接管脚本必须自带主机名、全程尽力而为（出错写日志不抛出）、结尾 exit 0；又因脚本内容哈希参与一次性授权确认（内容变化会重新弹窗），生成的脚本必须逐字节稳定，不含时间戳之类易变内容。
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const 设置节 = '安装VSCode远程服务';
const 开关键 = '接管远程服务器安装';
const 钩子设置键 = 'remote.SSH.preconnect';
const 生成脚本前缀 = '接管安装-';
const 状态键_接管前设置 = '接管前的remote.SSH.preconnect';

function 激活(context) {
	const 对齐 = () => 对齐接管状态(context, true).catch(错误 => {
		console.error('[接管远程服务器安装] 开关对齐出错：' + 取错误信息(错误));
		vscode.window.showErrorMessage('接管远程服务器安装出错：' + 取错误信息(错误));
	});

	// 开关变化时立即接管或还原，并给出提示
	context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(事件 => {
		if (事件.affectsConfiguration(设置节 + '.' + 开关键)) {
			对齐();
		}
	}));

	// 启动时静默对齐一次：刷新主机清单、修补丢失的钩子，不打扰用户
	对齐接管状态(context, false).catch(错误 => {
		console.error('[接管远程服务器安装] 启动对齐出错：' + 取错误信息(错误));
		vscode.window.showErrorMessage('接管远程服务器安装出错：' + 取错误信息(错误));
	});
}

function 停用() { }

async function 对齐接管状态(context, 来自开关变化) {
	if (取开关值()) {
		await 执行接管(context, 来自开关变化);
	} else {
		await 执行还原(context, 来自开关变化);
	}
}

function 取开关值() {
	return Boolean(vscode.workspace.getConfiguration(设置节).get(开关键, false));
}

function 取钩子全局值() {
	const 详情 = vscode.workspace.getConfiguration().inspect(钩子设置键);
	return 详情 ? 详情.globalValue : undefined;
}

async function 写钩子全局值(值) {
	await vscode.workspace.getConfiguration().update(钩子设置键, 值, vscode.ConfigurationTarget.Global);
}

// 执行接管：把 remote.SSH.preconnect 换成指向本扩展生成脚本的主机映射，替换 Remote-SSH 自带安装
async function 执行接管(context, 来自开关变化) {
	// 取代的对象是 Remote-SSH 的安装步骤，Remote-SSH 不在场时其设置项未注册，VS Code 会拒绝写入 remote.SSH.preconnect
	if (!vscode.extensions.getExtension('ms-vscode-remote.remote-ssh')) {
		if (来自开关变化) {
			vscode.window.showWarningMessage('接管远程服务器安装需要 Remote-SSH 扩展，请先安装并启用 Remote-SSH，再开启开关。');
		}
		return;
	}
	const 模块路径 = 查找模块路径(context.extensionPath);
	const 发布通道 = /insiders/i.test(vscode.env.appName) ? '预览版' : '稳定版';
	const 保存目录 = context.globalStorageUri.fsPath;
	const 当前钩子 = 取钩子全局值();
	const 已由本扩展接管 = 判断是否本扩展的钩子(当前钩子, 保存目录);

	// 只在首次接管时记录接管前的取值；反复对齐（如每次启动）不得把本扩展自己的映射记成“原值”，否则还原与链式调用都会失真
	const 原设置 = 已由本扩展接管 ? context.globalState.get(状态键_接管前设置) : 当前钩子;
	if (!已由本扩展接管) {
		await context.globalState.update(状态键_接管前设置, 当前钩子 === undefined ? null : 当前钩子);
	}

	const 主机清单 = 收集主机清单(原设置);
	if (主机清单.length === 0) {
		if (来自开关变化) {
			vscode.window.showWarningMessage('接管远程服务器安装：未在 ~/.ssh/config 中发现任何主机，暂无可接管目标；请补充 SSH 配置后重开开关。');
		}
		return;
	}

	const 新钩子 = {};
	for (const 主机 of 主机清单) {
		新钩子[主机] = 生成接管脚本(保存目录, 主机, 模块路径, 发布通道, 取原preconnect脚本(原设置, 主机));
	}

	if (JSON.stringify(取钩子全局值()) !== JSON.stringify(新钩子)) {
		await 写钩子全局值(新钩子);
	}

	if (来自开关变化) {
		vscode.window.showInformationMessage('已接管 Remote-SSH 远程服务器安装：' + 主机清单.join('、') + '（共 ' + 主机清单.length + ' 个主机）此后由本模块安装远程服务器。');
	}
}

// 执行还原：把 remote.SSH.preconnect 恢复为接管前的取值，删除本扩展生成的脚本，Remote-SSH 恢复自带安装
async function 执行还原(context, 来自开关变化) {
	const 保存目录 = context.globalStorageUri.fsPath;
	const 当前钩子 = 取钩子全局值();
	const 已由本扩展接管 = 判断是否本扩展的钩子(当前钩子, 保存目录);
	const 原设置 = context.globalState.get(状态键_接管前设置);
	const 清理数量 = 清理生成脚本(保存目录);

	if (已由本扩展接管) {
		await 写钩子全局值(原设置 === null || 原设置 === undefined ? undefined : 原设置);
	}
	if (已由本扩展接管 || 清理数量 > 0) {
		await context.globalState.update(状态键_接管前设置, undefined);
		if (来自开关变化) {
			vscode.window.showInformationMessage('已还原：Remote-SSH 恢复自带的远程服务器安装。');
		}
	}
}

// 接管范围：~/.ssh/config（含 Include 展开）里的主机别名，再加上接管前映射里已有的主机（保证还原与链式调用不失真）
function 收集主机清单(原设置) {
	const 清单 = [];
	for (const 主机 of 解析SSH主机()) {
		if (!清单.includes(主机)) {
			清单.push(主机);
		}
	}
	if (原设置 && typeof 原设置 === 'object') {
		for (const 主机 of Object.keys(原设置)) {
			if (!清单.includes(主机)) {
				清单.push(主机);
			}
		}
	}
	return 清单;
}

// 接管前映射中该主机原有的 preconnect 脚本（字符串形式视为对全部主机生效），生成的接管脚本末尾会链式执行它
function 取原preconnect脚本(原设置, 主机) {
	if (typeof 原设置 === 'string' && 原设置.trim() !== '') {
		return 原设置;
	}
	if (原设置 && typeof 原设置 === 'object') {
		const 值 = 原设置[主机];
		if (typeof 值 === 'string' && 值.trim() !== '') {
			return 值;
		}
	}
	return '';
}

function 生成接管脚本(保存目录, 主机, 模块路径, 发布通道, 原脚本) {
	const 文件名 = 生成脚本前缀 + 主机.replace(/[\\/:*?"<>|]/g, '_') + '.ps1';
	const 文件路径 = path.join(保存目录, 文件名);
	const 目标内容 = '\ufeff' + 生成脚本内容(主机, 模块路径, 发布通道, 原脚本);
	const 现有内容 = fs.existsSync(文件路径) ? fs.readFileSync(文件路径, 'utf8') : '';
	if (现有内容 !== 目标内容) {
		fs.mkdirSync(保存目录, { recursive: true });
		// UTF-8 带 BOM：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 按 ANSI 误读，中文必乱码
		fs.writeFileSync(文件路径, 目标内容, 'utf8');
	}
	return 文件路径;
}

function 生成脚本内容(主机, 模块路径, 发布通道, 原脚本) {
	const 转义 = 文本 => String(文本).replace(/'/g, "''");
	return [
		'# 接管 Remote-SSH 的远程服务器安装步骤（由「接管远程服务器安装」扩展生成，请勿手工修改）',
		'# 主机：' + 主机 + '；发布通道：' + 发布通道 + '。全程尽力而为：出错只写日志、绝不阻断连接（preconnect 脚本非零退出会中止连接）。',
		"$模块路径 = '" + 转义(模块路径) + "'",
		"$主机 = '" + 转义(主机) + "'",
		"$原脚本 = '" + 转义(原脚本) + "'",
		'try {',
		'	# 先探免密：模块在需要密码时会交互收集，脱离终端会挂起，故探测不通过就放弃接管、交还 Remote-SSH 自带安装',
		'	& ssh -o BatchMode=yes -o ConnectTimeout=8 $主机 exit 0 | Out-Null',
		'	if ($LASTEXITCODE -ne 0) {',
		"		Write-Host ('[接管安装] {0} 未配置免密登录，跳过本次接管，保持 Remote-SSH 自带安装' -f $主机)",
		'	} else {',
		'		Import-Module -Name $模块路径 -Force -ErrorAction Stop',
		"		安装-VSCode远程服务 -远程主机 $主机 -本地版本 '" + 转义(发布通道) + "' -ErrorAction Stop",
		'	}',
		'} catch {',
		"	Write-Host ('[接管安装] 失败（不阻断连接）：{0}' -f $_.Exception.Message)",
		'}',
		"if ($原脚本 -ne '' -and (Test-Path -LiteralPath $原脚本)) {",
		'	# 链式执行接管前的原 preconnect 脚本，保持接管前的既有行为（如服务保活预部署）',
		'	try {',
		'		& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $原脚本 | Out-Null',
		'	} catch {',
		"		Write-Host ('[接管安装] 原 preconnect 脚本失败（不阻断连接）：{0}' -f $_.Exception.Message)",
		'	}',
		'}',
		'exit 0',
		''
	].join('\r\n');
}

function 清理生成脚本(保存目录) {
	let 数量 = 0;
	if (!fs.existsSync(保存目录)) {
		return 数量;
	}
	for (const 文件名 of fs.readdirSync(保存目录)) {
		if (文件名.startsWith(生成脚本前缀) && 文件名.endsWith('.ps1')) {
			fs.unlinkSync(path.join(保存目录, 文件名));
			数量 += 1;
		}
	}
	return 数量;
}

function 判断是否本扩展的钩子(值, 保存目录) {
	const 本扩展前缀 = path.join(保存目录, 生成脚本前缀).toLowerCase();
	const 是本扩展脚本 = 取值 => typeof 取值 === 'string' && 取值.toLowerCase().startsWith(本扩展前缀);
	if (是本扩展脚本(值)) {
		return true;
	}
	if (值 && typeof 值 === 'object') {
		return Object.keys(值).some(键 => 是本扩展脚本(值[键]));
	}
	return false;
}

// 模块与扩展同仓库共存：优先取扩展目录的同级「安装-VSCode远程服务」目录（工作区源文件），
// 其次取扩展内打包的副本 module/（打出来的 VSIX 装到扩展目录后前者不存在）
function 查找模块路径(扩展目录) {
	const 候选 = [
		path.join(扩展目录, '..', '安装-VSCode远程服务', 'Install-VSCodeRemoteServer.psd1'),
		path.join(扩展目录, 'module', 'Install-VSCodeRemoteServer.psd1')
	];
	for (const 候选路径 of 候选) {
		if (fs.existsSync(候选路径)) {
			return 候选路径;
		}
	}
	throw new Error('未找到 Install-VSCodeRemoteServer 模块，期望位置：' + 候选[0]);
}

// 递归展开 ~/.ssh/config 的 Host 与 Include，收集可直接用于连接的主机别名（跳过含通配符的模式名）
function 解析SSH主机() {
	const 结果 = [];
	const 已读文件 = new Set();

	function 读配置(文件路径) {
		const 规范路径 = path.resolve(文件路径);
		if (已读文件.has(规范路径) || !fs.existsSync(规范路径)) {
			return;
		}
		已读文件.add(规范路径);
		let 文本;
		try {
			文本 = fs.readFileSync(规范路径, 'utf8');
		} catch {
			return;
		}
		for (const 原始行 of 文本.split(/\r?\n/)) {
			const 行 = 原始行.replace(/#.*$/, '').trim();
			if (行 === '') {
				continue;
			}
			const 分隔位置 = 行.search(/\s/);
			const 关键词 = 分隔位置 === -1 ? 行 : 行.slice(0, 分隔位置);
			const 参数 = 分隔位置 === -1 ? '' : 行.slice(分隔位置).trim();
			if (/^host$/i.test(关键词)) {
				for (const 名字 of 参数.split(/\s+/)) {
					if (名字 !== '' && !/[*?!]/.test(名字) && !结果.includes(名字)) {
						结果.push(名字);
					}
				}
			} else if (/^include$/i.test(关键词)) {
				for (const 片段 of 参数.split(/\s+/)) {
					for (const 展开路径 of 展开含通配的路径(片段)) {
						读配置(展开路径);
					}
				}
			}
		}
	}

	读配置(path.join(os.homedir(), '.ssh', 'config'));
	return 结果;
}

// ssh config 的 Include 支持 ~ 前缀与文件名通配符，此处按最小实现展开
function 展开含通配的路径(模式) {
	let 已展开 = 模式;
	if (已展开.startsWith('~')) {
		已展开 = path.join(os.homedir(), 已展开.slice(1));
	}
	if (!/[*?[\]]/.test(path.basename(已展开))) {
		return [已展开];
	}
	const 目录 = path.dirname(已展开);
	const 基本名 = path.basename(已展开);
	try {
		const 正则 = new RegExp('^' + 基本名.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$', 'i');
		return fs.readdirSync(目录).filter(名字 => 正则.test(名字)).map(名字 => path.join(目录, 名字));
	} catch {
		return [];
	}
}

function 取错误信息(错误) {
	return 错误 instanceof Error ? 错误.message : String(错误);
}

module.exports = { activate: 激活, deactivate: 停用 };
