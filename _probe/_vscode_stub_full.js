// vscode 模块桩：让 terminalRescue.js / cdp.js 能在纯 node 下被 require（仓库自测专用，不进 VSIX）。
// 只覆盖这两个模块在 require 期与自测路径上用到的最小 API 面；真实救援流程不经这里。
module.exports = {
	env: { remoteName: undefined, logUri: undefined, appName: 'Visual Studio Code - Insiders' },
	commands: { executeCommand: () => Promise.resolve(), registerCommand: () => ({ dispose: () => {} }) },
	window: {
		createOutputChannel: () => ({ appendLine: () => {}, show: () => {}, dispose: () => {} }),
		createTerminal: () => { throw new Error('桩不支持 createTerminal'); },
		showWarningMessage: () => Promise.resolve(),
		showInformationMessage: () => Promise.resolve(),
		showErrorMessage: () => Promise.resolve(),
	},
	workspace: { workspaceFolders: undefined, getConfiguration: () => ({ get: () => undefined }) },
	Uri: { file: p => ({ scheme: 'file', path: p, fsPath: p, toString: () => 'file://' + p }), parse: s => ({ scheme: 'vscode-remote', authority: s, toString: () => s }) },
	StatusBarAlignment: { Left: 1, Right: 2 },
};
