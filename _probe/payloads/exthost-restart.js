// 载荷：在窗口内重启本地扩展宿主（只重启 ext host，不重载窗口）
// 为什么要这一步：preconnect 的 argv 超限缺陷已修好（手动实跑退出码 0、13.1 秒），但窗口内重解析仍立刻拿到
//   同一条 `non-zero exit code 1` —— 且那次 Remote-SSH 日志里**没有任何新的 preconnect 记录**，
//   说明扩展宿主进程内的解析器把失败结果缓存在内存里直接回放（平台侧的 _resolveAuthorityRequests 清不干净它）。
//   扩展宿主一重启，这份缓存就没了；窗口本身不动（DOM、编辑器、我架的信任桥接都保留）。
// 命令用平台自己的 workbench.action.restartExtensionHost（等价于用户在命令面板里点"重启扩展宿主"），
//   随后等 whenInstalledExtensionsRegistered 落定作为"扩展宿主已回来"的信号。
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString()};
	try{
		var root=W[K+'.root'];
		if(!root){ return {err:'钥匙未交接'}; }
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var 哨={__pending__:true};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(ok){ 计时=setTimeout(function(){ ok(哨); },ms); });
			return Promise.race([Promise.resolve().then(function(){ return p; }),超时]).then(function(v){ clearTimeout(计时); return v; })
				.catch(function(e){ clearTimeout(计时); return {__failed__:String(e&&e.message||e)}; });
		};
		var cmd=取服务('commandService');
		var ext=取服务('extensionService');
		out.命令服务=!!cmd;
		out.扩展服务在=!!ext;
		if(!cmd||!ext){ return out; }
		out.解析尝试次数前=(typeof ext._resolveAuthorityAttempt!=='undefined')?String(ext._resolveAuthorityAttempt):'无字段';
		// 扩展宿主是否活着：用扩展状态数量做粗略对照
		try{ out.扩展状态数量前=(ext._extensionStatus?(ext._extensionStatus.size||Object.keys(ext._extensionStatus).length):'?'); }catch(e){}
		try{
			var r=await race(cmd.executeCommand('workbench.action.restartExtensionHost'),8000);
			out.重启命令结果=(r===哨?'悬挂(8秒)':(r&&r.__failed__?'异常 '+r.__failed__:'已落定'));
		}catch(e){ out.重启命令异常=e.message; }
		// 如果命令弹了确认框，替用户点主按钮（不点就会卡住整个流程）
		try{
			var 框数=document.querySelectorAll('.monaco-dialog-box').length;
			out.弹框数=框数;
			if(框数>0){
				var 主钮=document.querySelector('.monaco-dialog-box .dialog-button.primary');
				out.主按钮文本=主钮?String(主钮.textContent||'').trim():'没找到主按钮';
				if(主钮){ 主钮.click(); out.已点主按钮=true; }
			}
		}catch(e){ out.弹框处理异常=e.message; }
		// 等扩展宿主回来（whenInstalledExtensionsRegistered 是公开 promise，扩展注册完即落定）
		var 回了='未知';
		for(var i=0;i<24;i++){
			await new Promise(function(ok){ setTimeout(ok,1000); });
			var r2=await race(ext.whenInstalledExtensionsRegistered(),1500);
			if(r2!==哨&&!(r2&&r2.__failed__)){ 回了='已注册(第'+(i+1)+'秒)'; break; }
			if(i===11){ 回了='仍在等(12秒)'; }
		}
		out.扩展宿主回归=回了;
		out.解析尝试次数后=(typeof ext._resolveAuthorityAttempt!=='undefined')?String(ext._resolveAuthorityAttempt):'无字段';
		try{ out.扩展状态数量后=(ext._extensionStatus?(ext._extensionStatus.size||Object.keys(ext._extensionStatus).length):'?'); }catch(e){}
		// 顺带报告信任桥接是否还在（重启 ext host 不会影响渲染进程服务，应当还在）
		out.桥接仍持有=!!W[K+'.trustBridge'];
		var wtm=取服务('workspaceTrustManagementService');
		try{ out.当前可信=(wtm?String(wtm.isWorkspaceTrusted()):'拿不到信任服务'); }catch(e){ out.当前可信='ERR '+e.message; }
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
