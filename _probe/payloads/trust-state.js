// 载荷：工作区信任状态精确取证（只读，不改任何状态）
// 动机（bundle 源码实证）：
//   ① TerminalInstance._createProcess() 第一步 `await this._ensureWorkspaceTrustedForProcess()`；本地终端（含 Remote-SSH 的隐藏连接终端，
//      实测其 _isRemoteResolverTerminal=false）会走 _trust() → requestWorkspaceTrust()
//   ② requestWorkspaceTrust()：已信任→直接 true；否则**第一次**调用建 _workspaceTrustRequestPromise 并 fire _onDidInitiateWorkspaceTrustRequest
//      （由该事件驱动弹模态框），**之后每次调用直接 return 同一个 promise，不再 fire 事件** ——
//      所以一旦第一个请求的对话框没弹出/没被应答，后续所有终端启动就永久悬挂且永远不会再弹框（实测 DOM 里 0 个对话框）。
//   ③ isTrustedByRemote() 依赖 _trustedAuthorities / _remoteAuthority.options.isTrusted —— 远程 authority 解析失败时这条也指望不上。
// 本载荷把这些量一次读全，并与健康窗口对照，用来决定「改哪一个状态量」而不是猜。
(async function(){
	try{
		var W=globalThis,K='__钥匙前缀__';
		var refs=W[K+'.refs'],root=W[K+'.root'];
		if(!refs||!root){ return {err:'钥匙未交接（本载荷需要在窗口里先做钥匙交接）'}; }
		var 哨={__pending__:true};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(ok){ 计时=setTimeout(function(){ ok(哨); },ms); });
			return Promise.race([Promise.resolve().then(function(){ return p; }),超时]).then(function(v){ clearTimeout(计时); return v; })
				.catch(function(e){ clearTimeout(计时); return {__failed__:String(e&&e.stack||e)}; });
		};
		var 判=function(r){ if(r===哨){ return '悬挂'; } if(r&&r.__failed__){ return '已拒绝: '+String(r.__failed__).slice(0,150); } if(r&&typeof r==='object'){ return '已落定: obj:'+((r.constructor&&r.constructor.name)||'?')+'{'+Object.keys(r).slice(0,8).join(',')+'}'; } return '已落定: '+String(r); };
		function 形(v){
			try{
				if(v===null){return 'null';} if(v===undefined){return 'undefined';}
				var t=typeof v;
				if(t==='string'){return 'str('+v.length+')'+(v.length<=70?':"'+v+'"':'');}
				if(t==='number'||t==='boolean'){return t+':'+String(v);}
				if(t==='function'){return 'fn:'+(v.name||'匿名');}
				if(Array.isArray(v)){return 'Array('+v.length+')';}
				if(v instanceof Map){return 'Map('+v.size+')';}
				if(v instanceof Set){return 'Set('+v.size+')';}
				if(typeof v.then==='function'){return 'Promise';}
				return 'obj:'+((v.constructor&&v.constructor.name)||'?')+'{'+Object.keys(v).slice(0,10).join(',')+'}';
			}catch(e){return '形?';}
		}
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		function 监听数(emitter){ try{ return (emitter&&typeof emitter._size==='number')?('监听者'+emitter._size):'无_size字段'; }catch(e){ return 'ERR'; } }
		var out={时间:new Date().toISOString(),窗口:document.title.slice(0,80)};

		var wtm=取服务('workspaceTrustManagementService');
		var wtr=取服务('workspaceTrustRequestService');
		var wte=取服务('workspaceTrustEnablementService');
		out.服务在场={管理:!!wtm,请求:!!wtr,启用:!!wte};
		if(wte){
			try{ out.isWorkspaceTrustEnabled=String(wte.isWorkspaceTrustEnabled()); }catch(e){ out.isWorkspaceTrustEnabled='ERR '+e.message; }
			try{ out.supportsWorkspaceTrust=形(wte.supportsWorkspaceTrust()); }catch(e){}
		}
		if(wtm){
			var 读=function(名){ try{ return 形(wtm[名]); }catch(e){ return 'ERR '+String(e.message).slice(0,50); } };
			out.管理状态={};
			['_isTrusted','_remoteAuthority','_storedTrustState','_canonicalWorkspace','_trustStateInfo','_trustedAuthorities','_untrustedFiles','_workspaceResolvedPromise','_workspaceTrustInitializedPromise','storageKey'].forEach(function(nm){ out.管理状态[nm]=读(nm); });
			// 已存的 URI 信任记录：远程工作区正常情况下这里应有 vscode-remote 条目
			try{
				var ti=wtm._trustStateInfo;
				if(ti&&ti.uriTrustInfo){
					out.uriTrustInfo条数=ti.uriTrustInfo.length;
					out.uriTrustInfo样例=ti.uriTrustInfo.slice(0,8).map(function(x){ try{ return String(x.uri&&x.uri.authority?x.uri.authority:x.uri)+'=' + x.trusted; }catch(e){ return 形(x); } });
				}
			}catch(e){ out.uriTrustInfo错误=String(e.message||e); }
			try{ out.isWorkspaceTrusted=String(wtm.isWorkspaceTrusted()); }catch(e){ out.isWorkspaceTrusted='ERR '+e.message; }
			try{ out.isWorkspaceTrustForced=String(wtm.isWorkspaceTrustForced()); }catch(e){ out.isWorkspaceTrustForced='ERR '+e.message; }
			try{ out.canSetWorkspaceTrust=String(wtm.canSetWorkspaceTrust()); }catch(e){ out.canSetWorkspaceTrust='ERR '+e.message; }
			try{ var us=wtm.getWorkspaceUris?wtm.getWorkspaceUris():null; out.工作区URI数=(us?us.length:'无该方法'); out.工作区URI=(us?Array.prototype.map.call(us,function(u){ try{ return String(u.scheme)+'://'+String(u.authority||'')+String(u.path||'').slice(0,50); }catch(e){ return 形(u); } }):null); }catch(e){ out.工作区URI='ERR '+e.message; }
			// 一次性待办：这两个 promise 决定信任态到底算不算"没初始化完"
			try{ out.竞速_workspaceResolved=判(await race(wtm.workspaceResolved,3000)); }catch(e){ out.竞速_workspaceResolved='ERR '+e.message; }
			try{ out.竞速_workspaceTrustInitialized=判(await race(wtm.workspaceTrustInitialized,3000)); }catch(e){ out.竞速_workspaceTrustInitialized='ERR '+e.message; }
			// 权威对象里的 options.isTrusted（远程 resolver 给的自动信任信号）
			try{ var ra=wtm._remoteAuthority; out.权威options=(ra&&ra.options)?形(ra.options):'无 _remoteAuthority'; out.权威options_isTrusted=(ra&&ra.options&&typeof ra.options.isTrusted!=='undefined')?String(ra.options.isTrusted):'无该字段'; }catch(e){ out.权威options='ERR '+e.message; }
		}
		if(wtr){
			out.请求服务状态={};
			try{ out.请求服务状态._workspaceTrustRequestPromise=形(wtr._workspaceTrustRequestPromise); }catch(e){}
			try{ out.请求服务状态._workspaceTrustRequestResolver=形(wtr._workspaceTrustRequestResolver); }catch(e){}
			try{ out.请求服务状态._resourcesTrustRequestPromises=形(wtr._resourcesTrustRequestPromises); }catch(e){}
			// 关键：谁来弹框？看事件发射器上的监听者数量（0 = 没人监听 → 永远不会弹框 = 死锁成因）
			try{ out.事件监听_发起信任请求=监听数(wtr._onDidInitiateWorkspaceTrustRequest); }catch(e){ out.事件监听_发起信任请求='ERR '+e.message; }
			try{ out.事件监听_启动时信任请求=监听数(wtr._onDidInitiateWorkspaceTrustRequestOnStartup); }catch(e){}
			if(wtr._workspaceTrustRequestPromise){
				out.竞速_信任请求Promise=判(await race(wtr._workspaceTrustRequestPromise,2000));
			}
			// 信任变更事件的监听者（completeWorkspaceTrustRequest 靠它把请求 promise 结算掉）
			try{ if(wtm){ out.事件监听_信任变更=监听数(wtm._onDidChangeTrust); } }catch(e){}
		}
		// 对照：终端服务侧连接态与 backend 的 perf 门（已知本地活、远程拒）
		try{ out.connectionState=String(refs.terminalService.connectionState); }catch(e){}
		try{ out.竞速_whenConnected=判(await race(refs.terminalService.whenConnected,1500)); }catch(e){}
		// DOM 里有没有对话框/信任提示
		try{
			out.DOM对话框数=document.querySelectorAll('.monaco-dialog-box').length;
			out.DOM信任提示数=document.querySelectorAll('.workspace-trust-editor, .workspace-trust-dialog, [class*=workspace-trust]').length;
			out.DOM遮罩数=document.querySelectorAll('.monaco-dialog-shadow, .dialog-shadow').length;
		}catch(e){ out.DOM错误=String(e.message||e); }
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out||{};
	}
})()
