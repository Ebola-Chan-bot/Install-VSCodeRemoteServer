// 接管远程服务器安装 扩展入口：把 Install-VSCodeRemoteServer 模块接入 Remote-SSH 的远程服务器安装步骤。
// 设置项：「安装VSCode远程服务.接管远程服务器安装」总开关；「安装VSCode远程服务.接管的主机」用户勾选的主机清单（命令「选择要接管的主机…」弹多选列表、实时扫描 ~/.ssh/config，勾选后写回该设置；直接在设置页编辑也行，保存即生效）。
// 勾选的主机：Remote-SSH 每次连接前先由本模块安装远程服务器（竞速供给 + 旧 glibc 自动部署官方 sysroot + CLI 引导预装），自带的安装步骤检测到服务端已就位便直接复用；未勾选的主机完全不动，保持自带安装——逐主机选择性隔离。
// 关闭开关：摘掉指向本扩展的钩子、删除生成的脚本——即「还原」（覆盖方式已把原脚本引用丢弃不可恢复，故还原不回填任何值）。
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

const 设置节 = '安装VSCode远程服务';
const 开关键 = '接管远程服务器安装';
const 钩子设置键 = 'remote.SSH.preconnect';
const 接管文件前缀 = '接管安装';
const 生成脚本前缀 = 接管文件前缀 + '-';
const 公共实现文件名 = '接管安装实现.ps1';
const 配置文件名 = '接管安装配置.json';
const 接管主机键 = '接管的主机';
const 保活主机键 = '启用保活的主机';
const 命令_选择主机 = 设置节 + '.选择接管主机';
const 状态键_接管方式 = '接管方式'; // 主机 → { 方式: '覆盖'|'自调', 原脚本 }；只对有过外部原脚本的主机记录
const 状态键_接管前设置 = '接管前的remote.SSH.preconnect'; // 旧版遗留记录，只读取用于追溯原脚本，用完即清

// 对齐串行化：勾选写回设置会再次触发对齐，链式排队避免两个对齐任务并发读写同一批文件
let 对齐队列 = Promise.resolve();
function 串行对齐(context, 交互) {
	const 执行 = () => 对齐接管状态(context, 交互).catch(错误 => {
		console.error('[接管远程服务器安装] 对齐出错：' + 取错误信息(错误));
		vscode.window.showErrorMessage('接管远程服务器安装出错：' + 取错误信息(错误));
	});
	对齐队列 = 对齐队列.then(执行, 执行);
	return 对齐队列;
}

function 激活(context) {
	// 开关或主机清单任一变化（设置页保存、手改 settings.json 都算）→ 立即对齐，交互模式下允许弹窗
	context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(事件 => {
		if (事件.affectsConfiguration(设置节 + '.' + 开关键) || 事件.affectsConfiguration(设置节 + '.' + 接管主机键) || 事件.affectsConfiguration(设置节 + '.' + 保活主机键)) {
			串行对齐(context, true);
		}
	}));

	// 多选勾选列表：实时扫描 ssh config 供勾选（先接管、后保活），确认后写回对应设置（写回即触发上面的对齐）
	context.subscriptions.push(vscode.commands.registerCommand(命令_选择主机, () => 选择接管主机().catch(错误 => {
		vscode.window.showErrorMessage('接管远程服务器安装：打开主机选择失败：' + 取错误信息(错误));
	})));

	// 启动时静默对齐一次：修补丢失的脚本与钩子，不打扰用户（需要决策的事项只留通知）
	串行对齐(context, false);
}

function 停用() { }

async function 对齐接管状态(context, 交互) {
	if (取开关值()) {
		await 执行接管(context, 交互);
	} else {
		await 执行还原(context, 交互);
	}
}

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

// 执行接管：为勾选的主机生成薄脚本并让 remote.SSH.preconnect 指向它们，替换 Remote-SSH 自带安装
async function 执行接管(context, 交互) {
	// 取代的对象是 Remote-SSH 的安装步骤，Remote-SSH 不在场时其设置项未注册，VS Code 会拒绝写入 remote.SSH.preconnect
	if (!vscode.extensions.getExtension('ms-vscode-remote.remote-ssh')) {
		if (交互) {
			vscode.window.showWarningMessage('接管远程服务器安装需要 Remote-SSH 扩展，请先安装并启用 Remote-SSH，再开启开关。');
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

	if (需要钩子.length === 0 && 交互) {
		const 选择 = await vscode.window.showWarningMessage('接管远程服务器安装：开关已开启，但还没有勾选任何接管或保活的主机。', '选择主机…');
		if (选择 === '选择主机…') {
			await vscode.commands.executeCommand(命令_选择主机);
		}
		// 即使不选也继续往下走：清单为空时重建钩子会把遗留的我方条目清干净（如用户清空了清单）
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
	// 自调主机的薄脚本、公共实现与配置都要保留：用户脚本里粘贴的那行可能还在，删文件会让连接直接报错
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

module.exports = { activate: 激活, deactivate: 停用 };
