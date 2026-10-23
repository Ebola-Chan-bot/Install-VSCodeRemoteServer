// 接管远程服务器安装 扩展入口：把 Install-VSCodeRemoteServer 模块接入 Remote-SSH 的远程服务器安装步骤。
// 设置项：「安装VSCode远程服务.接管的主机」「安装VSCode远程服务.启用保活的主机」两份用户勾选的主机清单（命令「选择接管与保活的主机…」弹多选列表、实时扫描 ~/.ssh/config，勾选后写回设置；直接在设置页编辑也行，保存即生效）。没有总开关：勾选哪些主机就接管/保活哪些主机，两份清单都为空即整体还原。
// 勾选的主机：Remote-SSH 每次连接前先由本模块安装远程服务器（竞速供给 + 旧 glibc 自动部署官方 sysroot + CLI 引导预装），自带的安装步骤检测到服务端已就位便直接复用；未勾选的主机完全不动，保持自带安装——逐主机选择性隔离。
// 取消勾选全部主机（两份清单都为空）：摘掉指向本扩展的钩子、删除生成的脚本——即「还原」（覆盖方式已把原脚本引用丢弃不可恢复，故还原不回填任何值）。
//
// 机制依据（Remote-SSH 0.128 源码实测：out/extension.js 的 preconnectScript）：remote.SSH.preconnect 取字符串时对全部主机生效、取对象时按主机映射；Windows 上必须是 .ps1，以 spawn('powershell.exe', ['-NoProfile','-ExecutionPolicy','Bypass','-File', 脚本路径],
// { stdio: ['ignore','pipe','pipe'] }) 调用——参数硬编码、不注入环境变量、不设工作目录、标准输入为 ignore，脚本运行时对自己被哪台主机触发一无所知（主机名只被用来挑路径，不传下来），故唯一能携带主机名的途径就是每主机一个薄脚本。非零退出会中止连接；脚本内容 sha256 参与一次性授权确认（内容变化即重新弹窗）。
//
// 因此本扩展把职责拆成三个文件（都在 globalStorage 目录）：
//   接管安装-<主机>.ps1  薄脚本，内容只有主机名 + 一行调用，逐字节稳定，是被授权哈希的那个文件；`接管安装实现.ps1`公共实现，从扩展目录原样复制（不在这里拼字符串），Remote-SSH 不读它，改逻辑不会重新弹窗；`接管安装配置.json`模块路径、发布通道与各主机启用的能力（接管安装 / 服务保活）——易变信息集中在此，同样不参与授权。薄脚本用 $PSScriptRoot 找同目录的实现文件，所以扩展升级换目录也不会改薄脚本内容。启用保活的主机同样生成薄脚本挂 preconnect，连接时幂等检修保活包装（部署/升级/自愈），VS Code 更新到新提交号后下一次连接即自动补上。
//
// 主机接管前已有外部 preconnect 脚本时绝不自动套壳，弹窗让用户三选一（决策持久化在 globalState，只问一次）：直接覆盖：钩子改指我方薄脚本，原脚本引用被丢弃（不可恢复，还原时也不回填）；复制调用代码：该主机的钩子完全不动，一行调用代码复制到剪贴板由用户自己粘进原脚本，调用链变成 Remote-SSH → 用户脚本 → 我方薄脚本；还原时扩展对该主机不做任何事，只提示手动删除那行（其薄脚本与公共文件必须保留：用户没删行之前还要靠它们干活，删了会让连接直接报错）。
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const 终端救援 = require('./terminalRescue.js');

const 设置节 = '安装VSCode远程服务';
const 钩子设置键 = 'remote.SSH.preconnect';
const 接管文件前缀 = '接管安装';
const 生成脚本前缀 = 接管文件前缀 + '-';
const 公共实现文件名 = '接管安装实现.ps1';
const 配置文件名 = '接管安装配置.json';
const 接管主机键 = '接管的主机';
const 保活主机键 = '启用保活的主机';
const 命令_选择主机 = 设置节 + '.选择接管主机';
const 命令_诊断终端通道 = 设置节 + '.诊断终端通道';
const 状态键_接管方式 = '接管方式'; // 主机 → { 方式: '覆盖'|'自调', 原脚本 }；只对有过外部原脚本的主机记录
const 状态键_接管前设置 = '接管前的remote.SSH.preconnect'; // 旧版遗留记录，只读取用于追溯原脚本，用完即清

// 对齐串行化：勾选写回设置会再次触发对齐，链式排队避免两个对齐任务并发读写同一批文件
let 对齐队列 = Promise.resolve();
function 串行对齐(context, 交互) {
	const 执行 = () => 执行接管(context, 交互).catch(错误 => {
		console.error('[接管远程服务器安装] 对齐出错：' + 取错误信息(错误));
		vscode.window.showErrorMessage('接管远程服务器安装出错：' + 取错误信息(错误));
	});
	对齐队列 = 对齐队列.then(执行, 执行);
	return 对齐队列;
}

function 激活(context) {
	// 主机清单变化（设置页保存、手改 settings.json 都算）→ 立即对齐，交互模式下允许弹窗
	context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(事件 => {
		if (事件.affectsConfiguration(设置节 + '.' + 接管主机键) || 事件.affectsConfiguration(设置节 + '.' + 保活主机键)) {
			串行对齐(context, true);
		}
	}));

	// 多选勾选列表：实时扫描 ssh config 供勾选（先接管、后保活），确认后写回对应设置（回写即触发上面的对齐）
	context.subscriptions.push(vscode.commands.registerCommand(命令_选择主机, () => 选择接管主机().catch(错误 => {
		vscode.window.showErrorMessage('接管远程服务器安装：打开主机选择失败：' + 取错误信息(错误));
	})));

	// 手动命令：探测/诊断/救援本窗口终端通道（探测正常时只报平安；死亡时走完整救援阶梯且逃逸不受冷却限制）
	context.subscriptions.push(vscode.commands.registerCommand(命令_诊断终端通道, () => 启动终端救援(context, null, true)));

	// 启动时静默对齐一次：修补丢失的脚本与钩子，不打扰用户（需要决策的事项只留通知）
	串行对齐(context, false);

	// 安装命令未执行（窗口终端通道死亡）自动检测：启动后立查一次，此后每 5 分钟复查；命中即自动走救援阶梯（探测→restartPtyHost→CDP 深诊断→新窗口逃逸）
	检测安装命令未执行(context);
	const 检测定时器 = setInterval(() => 检测安装命令未执行(context), 5 * 60 * 1000);
	context.subscriptions.push({ dispose: () => clearInterval(检测定时器) });

	// 开发自测钩子：隔离 dev host 里设 VSI_RESCUE_SELFTEST=1 时激活后自动跑一遍救援阶梯（正常环境此变量不存在，无任何影响）
	if (process.env.VSI_RESCUE_SELFTEST === '1') {
		setTimeout(() => 启动终端救援(context, null, true), 4000);
	}
}

function 停用() { }

// 「选择接管与保活的主机…」命令：两个多选 QuickPick 依次勾选（接管安装 / 服务保活，相互独立可重叠），候选实时来自 ssh config（含已勾选但已从 config 消失的，便于取消）
async function 选择接管主机() {
	const 候选 = 解析SSH主机();
	const 当前接管 = 取主机清单设置(接管主机键);
	const 当前保活 = 取主机清单设置(保活主机键);
	for (const 名单 of [当前接管, 当前保活]) {
		for (const 主机 of 名单) {
			if (!候选.includes(主机)) {
				候选.push(主机);
			}
		}
	}
	if (候选.length === 0) {
		vscode.window.showWarningMessage('接管远程服务器安装：未在 ~/.ssh/config 中发现任何主机，请补充 SSH 配置后再试。');
		return;
	}
	const 勾选接管 = await vscode.window.showQuickPick(候选.map(名字 => ({ label: 名字, picked: 当前接管.includes(名字) })), {
		canPickMany: true,
		title: '选择要接管远程服务器安装的主机',
		placeHolder: '空格切换勾选，回车确定；未勾选的主机保持 Remote-SSH 自带安装'
	});
	if (勾选接管 === undefined) {
		return; // 第一步取消：全部设置不变
	}
	await vscode.workspace.getConfiguration(设置节).update(接管主机键, 勾选接管.map(项 => 项.label), vscode.ConfigurationTarget.Global);

	const 勾选保活 = await vscode.window.showQuickPick(候选.map(名字 => ({ label: 名字, picked: 当前保活.includes(名字) })), {
		canPickMany: true,
		title: '选择要启用服务保活的主机',
		placeHolder: '空格切换勾选，回车确定；保活让 server 脱离 SSH 会话存活、断线热附着，preconnect 时自动检修'
	});
	if (勾选保活 === undefined) {
		return; // 第二步取消：接管清单已生效，保活清单保持原样
	}
	await vscode.workspace.getConfiguration(设置节).update(保活主机键, 勾选保活.map(项 => 项.label), vscode.ConfigurationTarget.Global);
}

// 读主机清单类设置（「接管的主机」「启用保活的主机」）：去重、去空、去首尾空白（用户可能手改 settings.json）
function 取主机清单设置(键) {
	const 值 = vscode.workspace.getConfiguration(设置节).get(键, []);
	if (!Array.isArray(值)) {
		return [];
	}
	const 结果 = [];
	for (const 项 of 值) {
		if (typeof 项 === 'string' && 项.trim() !== '' && !结果.includes(项.trim())) {
			结果.push(项.trim());
		}
	}
	return 结果;
}

function 取钩子全局值() {
	const 详情 = vscode.workspace.getConfiguration().inspect(钩子设置键);
	return 详情 ? 详情.globalValue : undefined;
}

async function 写钩子全局值(值) {
	await vscode.workspace.getConfiguration().update(钩子设置键, 值, vscode.ConfigurationTarget.Global);
}

// 执行接管：为勾选的主机生成薄脚本并让 remote.SSH.preconnect 指向它们，替换 Remote-SSH 自带安装；两份清单都为空时整体还原
async function 执行接管(context, 交互) {
	// 取代的对象是 Remote-SSH 的安装步骤，Remote-SSH 不在场时其设置项未注册，VS Code 会拒绝写入 remote.SSH.preconnect
	if (!vscode.extensions.getExtension('ms-vscode-remote.remote-ssh')) {
		if (交互) {
			vscode.window.showWarningMessage('接管远程服务器安装需要 Remote-SSH 扩展，请先安装并启用 Remote-SSH。');
		}
		return;
	}
	const 模块路径 = 查找模块路径(context.extensionPath);
	const 发布通道 = /insiders/i.test(vscode.env.appName) ? '预览版' : '稳定版';
	const 保存目录 = context.globalStorageUri.fsPath;
	const 当前钩子 = 取钩子全局值();
	// 旧版本（全量自动接管）留下的记录：只作为追溯外部原脚本的第二来源，消费后清除
	const 遗留原设置 = context.globalState.get(状态键_接管前设置);
	const 方式记录 = context.globalState.get(状态键_接管方式) || {};
	let 接管清单 = 取主机清单设置(接管主机键);
	let 保活清单 = 取主机清单设置(保活主机键);

	// 旧版升级迁移：新设置为空、但钩子里已有我方脚本时，把这些主机视为已勾选写回设置，避免升级后接管静默失效
	if (接管清单.length === 0 && !交互 && 当前钩子 && typeof 当前钩子 === 'object') {
		const 迁移清单 = Object.keys(当前钩子).filter(主机 => 是我方脚本(当前钩子[主机], 保存目录));
		if (迁移清单.length > 0) {
			接管清单 = 迁移清单;
			await vscode.workspace.getConfiguration(设置节).update(接管主机键, 迁移清单, vscode.ConfigurationTarget.Global);
			vscode.window.showInformationMessage('接管远程服务器安装：已从旧版本迁移 ' + 迁移清单.length + ' 台主机到「接管的主机」设置，可随时增删。');
		}
	}

	// 需要 preconnect 钩子的主机 = 启用接管 ∪ 启用保活：保活也要在每次连接时检修（幂等部署/升级/自愈包装）
	let 需要钩子 = [...接管清单];
	for (const 主机 of 保活清单) {
		if (!需要钩子.includes(主机)) {
			需要钩子.push(主机);
		}
	}

	// 两份清单都为空 = 没有任何主机被勾选：整体还原（摘钩子、删生成文件），接管范围完全由清单决定
	if (需要钩子.length === 0) {
		await 执行还原(context, 交互);
		return;
	}

	// 有外部原脚本且尚未决策的主机：交互时逐个弹窗询问；启动静默对齐时不打扰，只留通知并跳过这些主机
	const 待决策 = [];
	for (const 主机 of 需要钩子) {
		if (方式记录[主机]) {
			continue;
		}
		const 原脚本 = 取外部原脚本(当前钩子, 遗留原设置, 主机, 保存目录);
		if (原脚本 !== '') {
			待决策.push({ 主机: 主机, 原脚本: 原脚本 });
		}
	}
	let 有跳过 = false;
	if (待决策.length > 0) {
		if (交互) {
			for (const 项 of 待决策) {
				const 结果 = await 询问原脚本处理(项, 当前钩子, 保存目录);
				if (结果 === null) {
					// 跳过/关窗：等同不勾选此主机，两个清单里都同步移除
					有跳过 = true;
					接管清单 = 接管清单.filter(名字 => 名字 !== 项.主机);
					保活清单 = 保活清单.filter(名字 => 名字 !== 项.主机);
					需要钩子 = 需要钩子.filter(名字 => 名字 !== 项.主机);
				} else {
					方式记录[项.主机] = { 方式: 结果.方式, 原脚本: 项.原脚本 };
					if (结果.方式 === '自调') {
						await vscode.env.clipboard.writeText(结果.调用行);
						vscode.window.showInformationMessage('接管远程服务器安装：主机「' + 项.主机 + '」的调用代码已复制到剪贴板，请粘贴进它的原脚本（开头或结尾均可）：\n' + 项.原脚本 + '\n\n粘贴内容：\n' + 结果.调用行);
					}
				}
			}
		} else {
			const 名字串 = 待决策.map(项 => 项.主机).join('、');
			vscode.window.showWarningMessage('接管远程服务器安装：主机（' + 名字串 + '）接管前已配置 preconnect 脚本，需要选择处理方式后才能接管或保活，本次已跳过。', '立即处理').then(选择 => {
				if (选择 === '立即处理') {
					串行对齐(context, true);
				}
			});
			const 待决策主机 = 待决策.map(项 => 项.主机);
			接管清单 = 接管清单.filter(名字 => !待决策主机.includes(名字));
			保活清单 = 保活清单.filter(名字 => !待决策主机.includes(名字));
			需要钩子 = 需要钩子.filter(名字 => !待决策主机.includes(名字));
		}
	}

	// 先持久化决策再写设置：写设置会触发新一轮对齐，决策必须先落盘才不会重复弹窗
	await context.globalState.update(状态键_接管方式, 方式记录);
	if (遗留原设置 !== undefined) {
		await context.globalState.update(状态键_接管前设置, undefined);
	}
	if (有跳过) {
		await vscode.workspace.getConfiguration(设置节).update(接管主机键, 接管清单, vscode.ConfigurationTarget.Global);
		await vscode.workspace.getConfiguration(设置节).update(保活主机键, 保活清单, vscode.ConfigurationTarget.Global);
	}

	// 薄脚本：覆盖主机由钩子直接调用，自调主机由用户粘贴的那行调用，两者都需要生成
	const 我方条目 = {};
	for (const 主机 of 需要钩子) {
		我方条目[主机] = 生成接管脚本(保存目录, 主机);
	}
	// 易变信息全部进配置文件与公共实现，薄脚本只留主机名，避免逻辑或路径变化重新触发授权确认
	部署公共文件(context.extensionPath, 保存目录, {
		模块路径: 模块路径,
		本地版本: 发布通道,
		接管主机: 接管清单,
		保活主机: 保活清单,
		// 平台提示取自 Remote-SSH 自己的 remotePlatform 设置：Windows 主机上单会话（sh/base64）必失败，提前告知模块跳过那次徒劳尝试
		平台提示映射: (vscode.workspace.getConfiguration('remote.SSH').get('remotePlatform') || {})
	});

	const 新钩子 = 重建钩子(当前钩子, 方式记录, 我方条目, 保存目录);
	if (JSON.stringify(取钩子全局值()) !== JSON.stringify(新钩子)) {
		await 写钩子全局值(新钩子);
	}
	// 自调主机的薄脚本可能仍被用户脚本里粘贴的那行引用（决策有记录就保留），其余不再选中的薄脚本清掉
	const 保留主机 = new Set(需要钩子);
	for (const 主机 of Object.keys(方式记录)) {
		if (方式记录[主机] && 方式记录[主机].方式 === '自调') {
			保留主机.add(主机);
		}
	}
	清理多余薄脚本(保存目录, [...保留主机]);

	if (交互 && (接管清单.length > 0 || 保活清单.length > 0)) {
		const 说明 = [];
		if (接管清单.length > 0) {
			说明.push('接管安装：' + 接管清单.join('、'));
		}
		if (保活清单.length > 0) {
			说明.push('服务保活（preconnect 时自动检修）：' + 保活清单.join('、'));
		}
		vscode.window.showInformationMessage('接管远程服务器安装已配置——' + 说明.join('；') + '。未勾选的主机保持 Remote-SSH 自带安装。');
	}
}

// 执行还原：摘掉指向本扩展的钩子、删除生成文件；「自调」方式接管的主机扩展不做任何事，只提示手动删除粘贴的调用行
async function 执行还原(context, 交互) {
	const 保存目录 = context.globalStorageUri.fsPath;
	const 当前钩子 = 取钩子全局值();
	const 方式记录 = context.globalState.get(状态键_接管方式) || {};
	const 自调主机 = Object.keys(方式记录).filter(主机 => 方式记录[主机] && 方式记录[主机].方式 === '自调');

	const 是本扩展的 = 判断是否本扩展的钩子(当前钩子, 保存目录);
	if (是本扩展的) {
		let 新值 = undefined;
		if (当前钩子 && typeof 当前钩子 === 'object') {
			新值 = {};
			for (const 键 of Object.keys(当前钩子)) {
				if (!是我方脚本(当前钩子[键], 保存目录)) {
					新值[键] = 当前钩子[键];
				}
			}
			if (Object.keys(新值).length === 0) {
				新值 = undefined;
			}
		}
		await 写钩子全局值(新值);
	}
	// 自调主机的薄脚本、公共实现与配置都要保留：用户脚本里粘贴的那行可能还在，删文件会让它的连接直接报错
	const 清理数量 = 清理生成脚本(保存目录, 自调主机);
	await context.globalState.update(状态键_接管方式, undefined);
	await context.globalState.update(状态键_接管前设置, undefined);

	if (交互) {
		if (自调主机.length > 0) {
			const 明细 = 自调主机.map(主机 => '「' + 主机 + '」→ ' + ((方式记录[主机] || {}).原脚本 || '（原脚本路径未记录）')).join('\n');
			vscode.window.showWarningMessage('已还原：Remote-SSH 恢复自带的远程服务器安装。\n\n以下主机当初选择了「复制调用代码自行粘贴」，本扩展不改您的任何文件，请手动删掉当初粘贴进原脚本的那一行调用代码：\n' + 明细 + '\n\n删除之前，这些主机连接时仍会经那一行由本模块安装。');
		} else if (是本扩展的 || 清理数量 > 0) {
			vscode.window.showInformationMessage('已还原：Remote-SSH 恢复自带的远程服务器安装。');
		}
	}
}

// 钩子值是否指向本扩展生成的脚本（薄脚本都在 globalStorage 目录下、统一前缀；路径大小写不敏感）。这同时是防自引用守卫：绝不能把我方脚本当“外部原脚本”去调用（会自我递归），也不能拿它当用户资产去“还原”。
function 是我方脚本(值, 保存目录) {
	if (typeof 值 !== 'string' || 值.trim() === '') {
		return false;
	}
	const 自家前缀 = path.join(path.resolve(保存目录), 生成脚本前缀).toLowerCase();
	try {
		return path.resolve(值).toLowerCase().startsWith(自家前缀);
	} catch {
		return false;
	}
}

// 该主机接管前配置的外部（非本扩展生成）preconnect 脚本：先看现行钩子，再查旧版本遗留的记录；没有则返回 ''
function 取外部原脚本(当前钩子, 遗留原设置, 主机, 保存目录) {
	for (const 设置 of [当前钩子, 遗留原设置]) {
		let 值;
		if (typeof 设置 === 'string') {
			值 = 设置; // 字符串形式对全部主机生效
		} else if (设置 && typeof 设置 === 'object') {
			值 = 设置[主机];
		}
		if (typeof 值 === 'string' && 值.trim() !== '' && !是我方脚本(值, 保存目录)) {
			return 值;
		}
	}
	return '';
}

// 询问外部原脚本的处理方式：覆盖丢弃 / 复制调用代码自行粘贴 / 跳过不接管；返回 null 表示跳过
async function 询问原脚本处理(项, 当前钩子, 保存目录) {
	const 覆盖 = '直接覆盖（不可恢复）';
	const 自调 = '复制调用代码自行粘贴';
	const 跳过 = '跳过此主机';
	const 补充警示 = typeof 当前钩子 === 'string'
		? '\n\n注意：原设置是字符串形式，对所有主机生效。覆盖后设置改为按主机映射，其它主机将不再执行该脚本。'
		: '';
	const 选择 = await vscode.window.showWarningMessage(
		'主机「' + 项.主机 + '」接管前已配置 preconnect 脚本，如何处理？',
		{
			modal: true,
			detail: '原脚本：' + 项.原脚本 + 补充警示
				+ '\n\n直接覆盖：钩子改指本扩展脚本，原脚本不再被执行、引用丢失后不可恢复。'
				+ '\n复制调用代码：您的脚本与钩子一概不动，一行调用代码复制到剪贴板，由您粘贴进原脚本（调用链：Remote-SSH → 您的脚本 → 接管安装）。'
				+ '\n跳过：此主机不接管安装、也不做保活检修，保持原有行为。'
		},
		覆盖, 自调, 跳过
	);
	if (选择 === 覆盖) {
		return { 方式: '覆盖' };
	}
	if (选择 === 自调) {
		return { 方式: '自调', 调用行: 生成自调行(保存目录, 项.主机) };
	}
	return null; // 「跳过」、ESC、关窗都视为不接管
}

// 给用户粘进原脚本的一行调用代码：接管失败时同样以非零退出码中止连接，与直接覆盖的语义一致
function 生成自调行(保存目录, 主机) {
	const 薄路径 = path.join(保存目录, 薄脚本文件名(主机)).replace(/'/g, "''");
	return "& '" + 薄路径 + "'; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }";
}

// 无记录即视为覆盖方式：没问过意味着该主机没有外部原脚本，直接接管即可
function 取方式(方式记录, 主机) {
	const 记录 = 方式记录[主机];
	return 记录 && 记录.方式 === '自调' ? '自调' : '覆盖';
}

// 重建 remote.SSH.preconnect 全局值：勾选主机按决策写入，非勾选主机遗留的我方条目清掉；返回 undefined 表示清空设置
function 重建钩子(当前钩子, 方式记录, 我方条目, 保存目录) {
	let 基础 = {};
	let 字符串外置 = false;
	if (typeof 当前钩子 === 'string' && 当前钩子.trim() !== '' && !是我方脚本(当前钩子, 保存目录)) {
		字符串外置 = true;
	} else if (当前钩子 && typeof 当前钩子 === 'object') {
		基础 = { ...当前钩子 };
	}

	const 覆盖主机 = Object.keys(我方条目).filter(主机 => 取方式(方式记录, 主机) === '覆盖');
	if (字符串外置) {
		// 没有需要覆盖的主机：字符串设置原样保留（自调主机不改任何设置）
		if (覆盖主机.length === 0) {
			return 当前钩子;
		}
		// 有覆盖主机就必须转成按主机映射：字符串设置整体丢弃（决策弹窗里已明确警示不可恢复）
		基础 = {};
	}

	for (const 主机 of Object.keys(我方条目)) {
		if (取方式(方式记录, 主机) === '自调') {
			// 自调主机：钩子必须留在用户的原脚本上（它里面粘着我方调用行）；旧版升级时钩子可能已被改成我方薄脚本，这里把原脚本回填回去
			const 现值 = 基础[主机];
			if (typeof 现值 !== 'string' || 现值.trim() === '' || 是我方脚本(现值, 保存目录)) {
				const 原脚本 = (方式记录[主机] || {}).原脚本 || '';
				if (原脚本 !== '') {
					基础[主机] = 原脚本;
				} else {
					delete 基础[主机];
				}
			}
			continue;
		}
		基础[主机] = 我方条目[主机];
	}

	// 清理：仍指向我方薄脚本、但已不再以覆盖方式接管的主机（取消勾选或改选自调）
	for (const 键 of Object.keys(基础)) {
		if (是我方脚本(基础[键], 保存目录) && !覆盖主机.includes(键)) {
			delete 基础[键];
		}
	}
	return Object.keys(基础).length > 0 ? 基础 : undefined;
}

// 薄脚本文件名：主机名里 Windows 文件名非法字符换成下划线；钩子映射与自调行都用这一份定位，必须一致
function 薄脚本文件名(主机) {
	return 生成脚本前缀 + 主机.replace(/[\\/:*?"<>|]/g, '_') + '.ps1';
}

function 生成接管脚本(保存目录, 主机) {
	const 文件路径 = path.join(保存目录, 薄脚本文件名(主机));
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

// 对齐时的增量清理：删掉不再勾选主机遗留的薄脚本；传入的保留清单含自调主机（它们的薄脚本可能仍被用户脚本里粘贴的那行引用）
function 清理多余薄脚本(保存目录, 保留主机) {
	if (!fs.existsSync(保存目录)) {
		return;
	}
	const 应保留 = new Set((保留主机 || []).map(薄脚本文件名));
	for (const 文件名 of fs.readdirSync(保存目录)) {
		if (文件名.startsWith(生成脚本前缀) && 文件名.endsWith('.ps1') && !应保留.has(文件名)) {
			fs.unlinkSync(path.join(保存目录, 文件名));
		}
	}
}

// 还原时的全量清理：本扩展相关文件全删；但自调主机的薄脚本、连同公共实现与配置都要保留——
// 用户脚本里粘贴的调用行可能还在，删了文件会让它的连接直接报错（扩展对自调主机“不做任何事”也包含这一点）
function 清理生成脚本(保存目录, 自调主机) {
	let 数量 = 0;
	if (!fs.existsSync(保存目录)) {
		return 数量;
	}
	const 保留 = new Set((自调主机 || []).map(薄脚本文件名));
	const 有保留 = 保留.size > 0;
	for (const 文件名 of fs.readdirSync(保存目录)) {
		if (!文件名.startsWith(接管文件前缀) || !(文件名.endsWith('.ps1') || 文件名.endsWith('.json'))) {
			continue;
		}
		if (有保留 && (保留.has(文件名) || 文件名 === 公共实现文件名 || 文件名 === 配置文件名)) {
			continue;
		}
		fs.unlinkSync(path.join(保存目录, 文件名));
		数量 += 1;
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

// ===== 窗口终端通道死亡的自动检测与救援 =====
// 故障形态（实测，VS Code 的上游缺陷）：某个窗口里 Remote-SSH 经终端下发的安装/连接命令既不执行也无回显——连接终端整段空白、ssh 进程根本没启动（远端 sshd 日志也无认证痕迹）、窗口反复重连只反复超时；病灶是窗口 renderer ↔ pty host 的终端通道在窗口进程内部坏了（更新换代期 pty host 懒启动撞上版本目录交接时最易触发），重载窗口/重装扩展/清理远端都够不着它，而同期新窗口对同一主机秒连成功。
// 检测（日志特征）只是触发器，定罪靠探针实测（terminalRescue.js）：createTerminal 限时竞速 processId。救援阶梯全自动：L1 restartPtyHost → L2 CDP 断点交接深诊断+安全修复（取证落盘 %TEMP%\vsi-terminal-rescue-report.json）→ L3 自动新窗口重开远程（实测 100% 有效），每主机逃逸冷却 10 分钟防窗口风暴。
const 状态键_终端失灵提示时刻 = '安装命令未执行提示时刻';
let 终端失灵提示已弹 = false;
let 救援进行中 = false;
let 救援日志通道 = null;
// 「扫描不到任何日志」只提醒一次：这是检测失明的可取证信号（2026-10-22 线上事故当时毫无痕迹，事后只能靠人工翻目录反推）
let 扫描空已提示 = false;
let logs根目录缓存 = null;

function 取救援日志通道() {
	if (!救援日志通道) { 救援日志通道 = vscode.window.createOutputChannel('接管安装·终端救援'); }
	return 救援日志通道;
}

function 检测安装命令未执行(context) {
	if (终端失灵提示已弹 || 救援进行中) { return; }
	try {
		const 名单 = [...new Set([...取主机清单设置(接管主机键), ...取主机清单设置(保活主机键)])];
		if (名单.length === 0) { return; }
		const 日志组 = 列近期RemoteSshLog();
		const 命中 = 找近期安装超时日志(名单, 日志组);
		if (日志组.length === 0 && !扫描空已提示) {
			扫描空已提示 = true;
			console.warn('[接管远程服务器安装] 终端超时检测近 20 分钟内没扫到任何 Remote-SSH 日志（logs 根=' + (找logs根目录() || '(未定位)')
				+ '，本会话=' + (找本会话目录名() || '(未知)') + '）：若本窗口正在连远程，说明日志扫描口径又被带偏，检测已失明，需人工复查 列近期RemoteSshLog');
		}
		if (!命中) { return; }
		终端失灵提示已弹 = true;
		context.globalState.update(状态键_终端失灵提示时刻, Date.now());
		void 启动终端救援(context, 命中.主机[0] || null, false);
	} catch (错误) {
		console.error('[接管远程服务器安装] 安装命令未执行检测出错：' + 取错误信息(错误));
	}
}

// 救援阶梯编排入口（检测触发与手动命令共用）。探测正常时说明超时另有原因（远端慢/网络/凭据），绝不误逃逸。
async function 启动终端救援(context, 主机, 手动) {
	if (救援进行中) { return; }
	救援进行中 = true;
	const 通道 = 取救援日志通道();
	const 日志 = 消息 => { 通道.appendLine('[' + new Date().toLocaleTimeString() + '] ' + 消息); console.log('[接管远程服务器安装·终端救援] ' + 消息); };
	日志('===== 救援开始（主机: ' + (主机 || '(自动判定)') + '，触发: ' + (手动 ? '手动命令' : '连接反复超时检测') + '）=====');
	try {
		const 结果 = await 终端救援.救援终端通道(context, 主机, 日志, { 手动 });
		if (结果.结果 === '健康') {
			日志('探针实测终端通道正常——反复超时另有原因（远端慢/网络/凭据等），不做窗口级救援');
			if (手动) {
				// 手动模式下顺带跑一次 L2 只读深诊断：验证 CDP 交接链路，并给出健康窗口的基线报告（backend 注册、connectionState 等）
				const 仅诊断 = await 终端救援.经CDP诊断并修复(日志, false);
				void vscode.window.showInformationMessage('终端通道探测：正常。' + (仅诊断 ? 'CDP 深诊断：' + JSON.stringify(仅诊断.诊断) : '（CDP 诊断跳过/失败，详见日志）'), '查看救援日志').then(选 => { if (选) { 通道.show(true); } });
			}
			return;
		}
		if (结果.结果 === '判定失败') {
			日志('探针判定失败（非通道死亡），未做任何救援：' + JSON.stringify(结果.详情?.探 ?? {}));
			if (手动) { void vscode.window.showWarningMessage('终端通道探测：无法判定（探针立即报错，不构成通道死亡证据）。详见日志。', '查看救援日志').then(选 => { if (选) { 通道.show(true); } }); }
			return;
		}
		if (结果.结果 === 'L1就地修复' || 结果.结果 === 'L2重启pty宿主') {
			日志('救援成功（' + 结果.结果 + '），本窗口可重试连接');
			void vscode.window.showInformationMessage('接管远程服务器安装：本窗口终端通道曾异常，已自动修复（' + 结果.结果 + '）。现在可以重试远程连接。', '查看救援日志').then(选 => { if (选) { 通道.show(true); } });
			return;
		}
		if (结果.结果 === '已逃逸') {
			日志('已自动在新窗口重开远程「' + 结果.详情.主机 + '」');
			void vscode.window.showWarningMessage(
				'接管远程服务器安装：本窗口终端通道已死亡且无法在窗口内自愈（VS Code 上游缺陷；重载本窗口无效）。已自动在新窗口重开远程「' + 结果.详情.主机 + '」，请在新窗口继续（本窗口可关闭）。',
				'查看救援日志', '关闭本窗口'
			).then(选 => {
				if (选 === '查看救援日志') { 通道.show(true); }
				else if (选 === '关闭本窗口') { vscode.commands.executeCommand('workbench.action.closeWindow'); }
			});
			return;
		}
		// 救援失败：保留手动兜底入口
		const 名单 = [...new Set([...取主机清单设置(接管主机键), ...取主机清单设置(保活主机键)])];
		void vscode.window.showWarningMessage(
			'接管远程服务器安装：本窗口终端通道已死亡，自动救援未成功' + (结果.详情?.冷却中 ? '（逃逸冷却中，稍后将自动重试）' : '') + '。在新窗口打开远程即可恢复。',
			'在新窗口打开…', '查看救援日志', '关闭本窗口'
		).then(选择 => {
			if (选择 === '在新窗口打开…') {
				在新窗口打开远程(主机, 名单).catch(错误 => {
					vscode.window.showErrorMessage('接管远程服务器安装：新窗口打开失败：' + 取错误信息(错误));
				});
			} else if (选择 === '查看救援日志') { 通道.show(true); }
			else if (选择 === '关闭本窗口') { vscode.commands.executeCommand('workbench.action.closeWindow'); }
		});
	} catch (错误) {
		日志('救援流程异常：' + 取错误信息(错误));
		console.error('[接管远程服务器安装] 终端救援异常：' + 取错误信息(错误));
	} finally {
		救援进行中 = false;
	}
}

// 近 20 分钟内被改写的 Remote-SSH 输出日志中找「同名主机 ≥2 次连接超时且无网络/凭据层报错」的窗口
// 日志文件列表由调用方传入（默认实扫）：解耦后可以用假造的目录树直接回归（_probe/rescue-detection-selftest.js）
function 找近期安装超时日志(名单, 日志组 = 列近期RemoteSshLog()) {
	let 最佳 = null;
	for (const 文件 of 日志组) {
		let 内容 = '';
		try { 内容 = fs.readFileSync(文件, 'utf8'); } catch (e) { continue; }
		// 真实网络/凭据故障自带明确报错特征，不属于终端服务异常，排除避免误报
		if (/Permission denied|Connection refused|Connection closed by|Could not resolve hostname|Network is unreachable|No route to host|Connection timed out/i.test(内容)) { continue; }
		const 次数 = (内容.match(/Connecting with SSH timed out|timed out after/gi) || []).length;
		if (次数 < 2) { continue; }
		const 主机 = 名单.filter(名 => {
			const hex = Buffer.from(名, 'utf8').toString('hex');
			return 内容.includes(hex) || 内容.includes(hex.toUpperCase()) || 内容.includes(名);
		});
		if (主机.length === 0) { continue; }
		if (!最佳 || 次数 > 最佳.次数) { 最佳 = { 主机, 次数 }; }
	}
	return 最佳;
}

// 所有窗口的扩展输出日志都在 <数据目录>\logs\<会话>\window<N>\exthost\output_logging_*\ 下。
// 会话目录的选取**必须由本窗口 logUri 定位 + 日志自身近期性决定，绝不能只按目录名倒序取前两个**：任何一次 CLI 调用（code-insiders --install-extension / --version，以及 npx vsce 等间接触发的启动器）都会新建一个只含 cli.log 的**空壳会话目录**。实测线上事故（2026-10-22）：一次调试连出 6 个空壳，把真实会话（含 window3 的 Remote-SSH 日志）挤到第 7 位，`.slice(0, 2)` 只扫到两个空壳 → 检测恒不命中 → 当天 12:46 与 14:21 两轮共 18 次 "Connecting with SSH timed out" 全都没触发自动救援，用户只能自己发现「窗口连不上」。空壳目录还会持续产生（每次装扩展都有），所以这条规则是长期约束，不是偶发。
function 列近期RemoteSshLog(最大会话数 = 12) {
	const 结果 = [];
	const 根 = 找logs根目录();
	if (!根) { return 结果; }
	const 截点 = Date.now() - 20 * 60 * 1000;
	const 本会话 = 找本会话目录名();
	let 会话;
	try { 会话 = fs.readdirSync(根).filter(名 => /^\d{8}T\d{6}$/.test(名)).sort().reverse().slice(0, 最大会话数); } catch (e) { return 结果; }
	// 本窗口所在会话必扫（放最前）：空壳目录再多也挤不掉它
	if (本会话 && 会话.indexOf(本会话) < 0) { 会话.unshift(本会话); }
	for (const 会 of 会话) {
		let 窗口目录;
		try { 窗口目录 = fs.readdirSync(path.join(根, 会)).filter(名 => /^window\d+$/.test(名)); } catch (e) { continue; }
		for (const 窗 of 窗口目录) {
			const 扩展宿主目录 = path.join(根, 会, 窗, 'exthost');
			let 输出目录;
			try { 输出目录 = fs.readdirSync(扩展宿主目录).filter(名 => 名.startsWith('output_logging')); } catch (e) { continue; }
			for (const 输 of 输出目录) {
				let 文件;
				try { 文件 = fs.readdirSync(path.join(扩展宿主目录, 输)).filter(名 => 名.endsWith('.log') && 名.includes('Remote - SSH')); } catch (e) { continue; }
				for (const 文 of 文件) {
					const 全路径 = path.join(扩展宿主目录, 输, 文);
					try { if (fs.statSync(全路径).mtimeMs >= 截点) { 结果.push(全路径); } } catch (e) { }
				}
			}
		}
	}
	return 结果;
}

function 找logs根目录() {
	// 本窗口的 logUri 形如 .../logs/<会话>/window<N>/exthost/<扩展标识>/...，逐级上溯到 logs 目录（顺带记住本会话目录名）
	const 日志Uri = vscode.env.logUri;
	if (日志Uri) {
		let 目录 = 日志Uri.fsPath;
		let 下级名 = '';
		while (目录) {
			if (path.basename(目录) === 'logs') { logs根目录缓存 = 目录; 本会话目录名缓存 = 下级名 || null; return 目录; }
			下级名 = path.basename(目录);
			const 上级 = path.dirname(目录);
			if (上级 === 目录) { break; }
			目录 = 上级;
		}
	}
	// 兜底：按产品名拼常见数据目录（此时拿不到本会话名，只能靠目录名倒序扫）
	const 产品目录 = { 'Visual Studio Code': 'Code', 'Visual Studio Code - Insiders': 'Code - Insiders', 'Visual Studio Code - Exploration': 'Code - Exploration' }[vscode.env.appName];
	if (产品目录 && process.env.APPDATA) { const p = path.join(process.env.APPDATA, 产品目录, 'logs'); logs根目录缓存 = p; return p; }
	return null;
}

// 本窗口所在会话目录名（如 20261022T121929）：列日志时必扫它，以免被 CLI 空壳会话目录挤出取名窗口
let 本会话目录名缓存 = null;
function 找本会话目录名() {
	if (本会话目录名缓存) { return 本会话目录名缓存; }
	找logs根目录();
	return 本会话目录名缓存;
}

async function 在新窗口打开远程(首选主机, 名单) {
	let 主机 = 首选主机;
	if (!主机) {
		主机 = await vscode.window.showQuickPick(名单, { placeHolder: '选择要在新窗口打开的主机' });
	}
	if (!主机) { return; }
	// Remote-SSH 的非 ASCII 主机 authority 采用 UTF-8 十六进制编码形态（与 code-insiders --remote ssh-remote+<hex> 实测一致）
	const authority = 'ssh-remote+' + Buffer.from(主机, 'utf8').toString('hex');
	await vscode.commands.executeCommand('vscode.open', vscode.Uri.parse('vscode-remote://' + authority + '/'));
}

// 检测 VS Code 或 Remote-SSH 版本更新，提示清理连接状态避免旧窗口 reload 失败
function 检测版本更新并清理状态(context) {
	const 状态键_上次版本 = 'lastSeenVersion';
	const 状态键_清理提示抑制 = 'cleanupPromptSuppressed';
	
	const 当前版本 = vscode.version;
	const 上次版本 = context.globalState.get(状态键_上次版本);
	
	if (上次版本 && 上次版本 !== 当前版本) {
		const 已抑制 = context.globalState.get(状态键_清理提示抑制, false);
		if (!已抑制) {
			vscode.window.showWarningMessage(
				'检测到 VS Code 已从 ' + 上次版本 + ' 更新至 ' + 当前版本 + '。若当前窗口重新加载后远程连接失败，请执行「Remote-SSH: Kill VS Code Server on Host」清理状态，或关闭当前窗口并重新打开。',
				'立即清理全部主机', '不再提示'
			).then(选择 => {
				if (选择 === '立即清理全部主机') {
					清理全部主机连接状态(context);
				} else if (选择 === '不再提示') {
					context.globalState.update(状态键_清理提示抑制, true);
				}
			});
		}
	}
	
	context.globalState.update(状态键_上次版本, 当前版本);
}

// 清理所有已配置主机的 Remote-SSH 连接状态
async function 清理全部主机连接状态(context) {
	const 接管的 = 取主机清单设置(接管主机键);
	const 保活的 = 取主机清单设置(保活主机键);
	const 全部主机 = Array.from(new Set([...接管的, ...保活的]));
	
	if (全部主机.length === 0) {
		vscode.window.showInformationMessage('未配置任何接管的主机，无需清理。');
		return;
	}
	
	try {
		for (const 主机 of 全部主机) {
			await vscode.commands.executeCommand('remote-ssh.killServerOnHost', 主机);
		}
		vscode.window.showInformationMessage('已清理 ' + 全部主机.length + ' 个主机的连接状态。关闭当前窗口并重新打开以建立全新连接。');
	} catch (错误) {
		vscode.window.showErrorMessage('清理连接状态时出错：' + 取错误信息(错误));
	}
}

// 测试钩子（_probe/rescue-detection-selftest.js 用）：日志扫描与会话目录选取的口径必须可回归，不得只在真实 VS Code 里验证
module.exports = {
	activate: 激活,
	deactivate: 停用,
	_测试: { 列近期RemoteSshLog, 找近期安装超时日志, 找logs根目录, 找本会话目录名 },
};
