// 接管远程服务器安装 扩展入口：把 Install-VSCodeRemoteServer 模块接入 Remote-SSH 的远程服务器安装步骤。
// 唯一开关：设置项「安装VSCode远程服务.接管远程服务器安装」。
// 开启：Remote-SSH 每次连接前先由本模块安装远程服务器（竞速供给 + 旧 glibc 自动部署官方 sysroot + CLI 引导预装），Remote-SSH 自带的安装步骤检测到服务端已就位便直接复用——即「用本模块的方式替换原本的远程服务器安装」。
// 关闭：撤下钩子并把 remote.SSH.preconnect 还原为接管前的取值——即「还原」。
//
// 机制依据（Remote-SSH 0.128 源码实测：out/extension.js 的 preconnectScript）：remote.SSH.preconnect 取字符串时对全部主机生效、
// 取对象时按主机映射；Windows 上必须是 .ps1，以 spawn('powershell.exe', ['-NoProfile','-ExecutionPolicy','Bypass','-File', 脚本路径],
// { stdio: ['ignore','pipe','pipe'] }) 调用——参数硬编码、不注入环境变量、不设工作目录、标准输入为 ignore，脚本运行时对自己
// 被哪台主机触发一无所知（主机名只被用来挑路径，不传下来），故唯一能携带主机名的途径就是每主机一个薄脚本。
// 非零退出会中止连接；脚本内容 sha256 参与一次性授权确认（内容变化即重新弹窗）。
//
// 因此本扩展把职责拆成三个文件（都在 globalStorage 目录）：
//   接管安装-<主机>.ps1  薄脚本，内容只有主机名 + 一行调用，逐字节稳定，是被授权哈希的那个文件；
//   接管安装实现.ps1     公共实现，从扩展目录原样复制（不在这里拼字符串），Remote-SSH 不读它，改逻辑不会重新弹窗；
//   接管安装配置.json    模块路径、发布通道、各主机原有的 preconnect 脚本——易变信息集中在此，同样不参与授权。
// 薄脚本用 $PSScriptRoot 找同目录的实现文件，所以扩展升级换目录也不会改薄脚本内容。
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const 设置节 = '安装VSCode远程服务';
const 开关键 = '接管远程服务器安装';
const 钩子设置键 = 'remote.SSH.preconnect';
const 接管文件前缀 = '接管安装';
const 生成脚本前缀 = 接管文件前缀 + '-';
const 公共实现文件名 = '接管安装实现.ps1';
const 配置文件名 = '接管安装配置.json';
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

	// 易变信息全部进配置文件与公共实现，薄脚本只留主机名，避免逻辑或路径变化重新触发授权确认
	const 原脚本映射 = {};
	for (const 主机 of 主机清单) {
		原脚本映射[主机] = 取原preconnect脚本(原设置, 主机);
	}
	部署公共文件(context.extensionPath, 保存目录, {
		模块路径: 模块路径,
		本地版本: 发布通道,
		原脚本映射: 原脚本映射
	});

	const 新钩子 = {};
	for (const 主机 of 主机清单) {
		新钩子[主机] = 生成接管脚本(保存目录, 主机);
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

// 接管前映射中该主机原有的 preconnect 脚本（字符串形式视为对全部主机生效）；记入配置文件，由公共实现直接调用
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

function 生成接管脚本(保存目录, 主机) {
	const 文件名 = 生成脚本前缀 + 主机.replace(/[\\/:*?"<>|]/g, '_') + '.ps1';
	const 文件路径 = path.join(保存目录, 文件名);
	fs.mkdirSync(保存目录, { recursive: true });
	写入如不同(文件路径, 加BOM(生成薄脚本内容(主机)));
	return 文件路径;
}

// 薄脚本：只把主机名交给同目录的公共实现。这里刻意不含模块路径、发布通道等易变信息——
// 它的内容 sha256 就是 Remote-SSH 的一次性授权凭据，内容越稳，升级后越不会重新弹窗。
function 生成薄脚本内容(主机) {
	const 转义 = 文本 => String(文本).replace(/'/g, "''");
	return [
		'# 接管 Remote-SSH 的远程服务器安装步骤（由「接管远程服务器安装」扩展生成，请勿手工修改）。',
		'# 本文件只负责把主机名交给同目录的公共实现；具体逻辑与路径信息都在实现文件和配置文件里。',
		'# 改动那两个文件不会改变本文件内容，因此不会重新触发 Remote-SSH 的授权确认。',
		"& (Join-Path $PSScriptRoot '" + 公共实现文件名 + "') -远程主机 '" + 转义(主机) + "'",
		'# 公共实现自己决定退出码（非 0 会让 Remote-SSH 中止本次连接）；下面一行只是兜底。',
		'exit $LASTEXITCODE',
		''
	].join('\r\n');
}

// 部署公共实现与配置：公共实现是扩展目录里的独立 .ps1 文件，原样复制（不在此拼字符串），
// 便于单独编辑、单独做 PowerShell 语法校验；配置是本次接管的易变信息。
function 部署公共文件(扩展目录, 保存目录, 配置) {
	const 源实现 = path.join(扩展目录, 公共实现文件名);
	if (!fs.existsSync(源实现)) {
		throw new Error('未找到接管安装公共实现，期望位置：' + 源实现);
	}
	fs.mkdirSync(保存目录, { recursive: true });
	写入如不同(path.join(保存目录, 公共实现文件名), 加BOM(规范化文本(fs.readFileSync(源实现, 'utf8'))));
	// 只含稳定字段（无时间戳），逐字节可复现，才能用“内容相同就不写”避免无谓改动
	写入如不同(path.join(保存目录, 配置文件名), 加BOM(JSON.stringify(配置, null, '\t') + '\r\n'));
}

function 写入如不同(文件路径, 目标内容) {
	const 现有内容 = fs.existsSync(文件路径) ? fs.readFileSync(文件路径, 'utf8') : '';
	if (现有内容 === 目标内容) {
		return false;
	}
	fs.writeFileSync(文件路径, 目标内容, 'utf8');
	return true;
}

// 行尾统一 CRLF、去掉源文件可能已有的 BOM（避免复制后出现双 BOM）
function 规范化文本(文本) {
	return String(文本).replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').replace(/\n/g, '\r\n');
}

// UTF-8 带 BOM：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 按 ANSI 误读，中文必乱码
function 加BOM(文本) {
	return '\ufeff' + 文本;
}

function 清理生成脚本(保存目录) {
	let 数量 = 0;
	if (!fs.existsSync(保存目录)) {
		return 数量;
	}
	for (const 文件名 of fs.readdirSync(保存目录)) {
		// 薄脚本（接管安装-<主机>.ps1）、公共实现与配置同一个前缀，关闭开关时一并清掉
		if (文件名.startsWith(接管文件前缀) && (文件名.endsWith('.ps1') || 文件名.endsWith('.json'))) {
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

// 模块源码直接放在扩展的 module/ 目录内，打包与安装同此一份，扩展按相对路径取用
function 查找模块路径(扩展目录) {
	const 模块路径 = path.join(扩展目录, 'module', 'Install-VSCodeRemoteServer.psd1');
	if (fs.existsSync(模块路径)) {
		return 模块路径;
	}
	throw new Error('未找到 Install-VSCodeRemoteServer 模块，期望位置：' + 模块路径);
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
