// 载荷：启动门控实测（只读；建一个瞬态隐藏探针终端，逐个竞速可疑的 await 门，用完销毁）
// 依据 bundle 源码实证：TerminalInstance._createProcess() 的第一步就是
//     if (this.isDisposed || !await this._ensureWorkspaceTrustedForProcess()) return;
//   —— 这一步若悬挂，后面 processManager.createProcess 永远不会被调用（与实测「backend._ptys 恒为 0、无 createProcess 调用」完全吻合）。
// 而 TerminalService 初始化链里还有两处 await 也可能永久悬挂（源码实证）：
//   await Promise.all(重连实例.map(r => once(r.onProcessReplayComplete)))    ← 远程重连实例的回放完成事件
//   await Promise.all(所有backend.map(r => r.getPerformanceMarks()))          ← 远程 backend 的 perf 走死掉的远程通道
// 本载荷把这几条候选逐一竞速，用数据指出真正卡住的那一处，避免凭猜动状态。
(async function(){
	try{
		var W=globalThis,K='__钥匙前缀__';
		var refs=W[K+'.refs'],root=W[K+'.root'];
		if(!refs||!root){ return {err:'钥匙未交接'}; }
		var 哨={__pending__:true};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(ok){ 计时=setTimeout(function(){ ok(哨); },ms); });
			return Promise.race([Promise.resolve().then(function(){ return p; }),超时]).then(function(v){ clearTimeout(计时); return v; })
				.catch(function(e){ clearTimeout(计时); return {__failed__:String(e&&e.stack||e)}; });
		};
		var 判=function(r){ if(r===哨){ return '悬挂'; } if(r&&r.__failed__){ return '已拒绝: '+String(r.__failed__).slice(0,160); } return '已落定: '+String(typeof r==='object'&&r?('obj:'+((r.constructor&&r.constructor.name)||'')):r); };
		function 形(v){
			try{
				if(v===null){return 'null';} if(v===undefined){return 'undefined';}
				var t=typeof v;
				if(t==='string'){return 'str('+v.length+')'+(v.length<=64?':"'+v+'"':'');}
				if(t==='number'||t==='boolean'){return t+':'+String(v);}
				if(t==='function'){return 'fn';}
				if(Array.isArray(v)){return 'Array('+v.length+')';}
				if(v instanceof Map){return 'Map('+v.size+')';}
				if(v instanceof Set){return 'Set('+v.size+')';}
				if(typeof v.then==='function'){return 'Promise';}
				return 'obj:'+((v.constructor&&v.constructor.name)||'?')+'{'+Object.keys(v).slice(0,10).join(',')+'}';
			}catch(e){return '形?';}
		}
		var out={时间:new Date().toISOString(),竞速:[]};
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var lb=W[K+'.localBackend'];

		// 建探针实例（本地 cwd）
		var 探针=null; var URI类=null;
		try{
			var 全部=(refs.terminalService.instances||[]).slice();
			var pm0=null; try{ pm0=全部[0]&&全部[0]._processManager; }catch(e){}
			if(!pm0&&全部.length){ try{ Object.getOwnPropertyNames(全部[0]).forEach(function(nm){ var d=Object.getOwnPropertyDescriptor(全部[0],nm); if(d&&!d.get&&d.value&&typeof d.value==='object'&&typeof d.value._instanceId==='number'){ pm0=d.value; } }); }catch(e){} }
			if(pm0&&pm0._cwdWorkspaceFolder&&pm0._cwdWorkspaceFolder.uri){ URI类=pm0._cwdWorkspaceFolder.uri.constructor; }
		}catch(e){}
		if(!URI类){ out.err='无 URI 构造器'; return out; }
		var 本地目录='__本地目录__';
		探针=await race(refs.terminalService.createTerminal({ name:'VSI门控探针', isTransient:true, hideFromUser:true, cwd:URI类.file(本地目录) }),6000);
		if(!探针||探针.__pending__||探针.__failed__){ out.创建='失败 '+判(探针); return out; }
		try{ if(!W[K+'.probeList']){ W[K+'.probeList']=[]; } W[K+'.probeList'].push(探针); }catch(e){}
		out.探针id=(function(){ try{ return 探针._processManager._instanceId; }catch(e){ return '?'; } })();

		// ① 信任门：先只读取证，再决定是否竞速。
		// 依据 bundle 源码：_ensureWorkspaceTrustedForProcess() = `this._isRemoteResolverTerminal || await this._trust()`
		// 而 _trust() 除配置开关外会 `await workspaceTrustRequestService.requestWorkspaceTrust(...)` —— **会弹模态对话框**。
		// 工作区不受信任时不得盲调，否则凭空向用户窗口弹框；canStartTerminal 同理（内部也走请求服务），一律不碰。
		var 信任服务名 = [];
		try {
			root._services._entries.forEach(function (x, k) { var s = ''; try { s = String(k); } catch (e) { } if (/trust/i.test(s)) { 信任服务名.push(s); } });
		} catch (e) { }
		out.信任相关服务 = 信任服务名;
		var wtm = 取服务('workspaceTrustManagementService');
		out.工作区信任管理 = 形(wtm);
		var 可信 = null;
		try { if (wtm) { 可信 = Boolean(wtm.isWorkspaceTrusted()); out.isWorkspaceTrusted = String(可信); } } catch (e) { out.isWorkspaceTrusted = '调用异常 ' + String(e.message || e); }
		try { if (wtm && typeof wtm.workspaceTrustEnabled !== 'undefined') { out.workspaceTrustEnabled = 形(wtm.workspaceTrustEnabled); } } catch (e) { }
		// DOM 里有没有对话框（模态框丢失/被遮是「信任门悬挂」的典型成因）
		try {
			var 对话框 = document.querySelectorAll('.monaco-dialog-box');
			out.DOM对话框数 = 对话框.length;
			out.DOM对话框可见数 = Array.prototype.filter.call(对话框, function (d) { return d.offsetParent !== null; }).length;
			out.DOM对话框文本 = [];
			for (var di = 0; di < 对话框.length && di < 6; di++) {
				out.DOM对话框文本.push(String(对话框[di].textContent || '').replace(/\s+/g, ' ').slice(0, 150));
			}
		} catch (e) { out.DOM对话框错误 = String(e.message || e); }
		// 现有实例的关键标记：Remote-SSH 的解析终端应当带 _isRemoteResolverTerminal（源码里它能跳过信任门）
		try {
			var 全部实例 = (refs.terminalService.instances || []).slice();
			out.实例标记 = 全部实例.map(function (it, i) {
				var r = { 序: i };
				try { r.id = it._processManager ? it._processManager._instanceId : '?'; } catch (e) { }
				try { r.远端 = (it.remoteAuthority === undefined ? 'local' : 'remote'); } catch (e) { }
				try { r.解析终端 = !!it._isRemoteResolverTerminal; } catch (e) { r.解析终端 = '无字段'; }
				try { r.title = String(it.title || '').slice(0, 30); } catch (e) { }
				try { r.pid类型 = String(typeof it.processId); } catch (e) { }
				try { r.进程态 = String(it._processManager.processState); } catch (e) { }
				try { r.特征终端 = !!(it.shellLaunchConfig && it.shellLaunchConfig.isFeatureTerminal); } catch (e) { }
				try { r.隐藏 = !!(it.shellLaunchConfig && it.shellLaunchConfig.hideFromUser); } catch (e) { }
				try { r.cwdScheme = String(it.shellLaunchConfig && it.shellLaunchConfig.cwd && it.shellLaunchConfig.cwd.scheme); } catch (e) { }
				return r;
			});
		} catch (e) { out.实例标记错误 = String(e && e.message || e); }
		try { out.配置_allowInUntrusted = 形(refs.terminalConfigurationService.config && refs.terminalConfigurationService.config.allowInUntrustedWorkspace); } catch (e) { }
		try {
			if (可信 === true) {
				out.竞速.push({ 门: '探针._ensureWorkspaceTrustedForProcess', 结果: 判(await race(探针._ensureWorkspaceTrustedForProcess(), 6000)) });
			} else {
				out.信任门 = '未测（isWorkspaceTrusted=' + String(可信) + '，该方法会 requestWorkspaceTrust 弹模态框，为避免凭空打扰用户只做只读判定）';
			}
		} catch (e) { out.竞速.push({ 门: '探针._ensureWorkspaceTrustedForProcess', 结果: '异常 ' + String(e.message || e) }); }
		// ①b 绕过信任门直调 createProcess（需 harness 传 VSI_BYPASS_TRUST=1）：判 pty 侧到底通不通
		if ('__绕过信任__' === 'true') {
			try {
				var pm直 = 探针._processManager;
				out.直调createProcess = 判(await race(pm直.createProcess(探针._shellLaunchConfig, 80, 30), 10000));
				out.直调后本地_ptys = (lb && lb._ptys) ? lb._ptys.size : null;
				out.直调后pid = String(探针.processId);
				out.直调后进程态 = String(pm直.processState);
			} catch (e) { out.直调异常 = String(e && e.stack || e); }
		} else {
			out.直调createProcess = '未执行（需 VSI_BYPASS_TRUST=1 才绕信任门，避免在未受信任工作区里旁路安全提示）';
		}

		// ② 终端服务初始化链上另外两处 await：重连组 / 各 backend 的 getPerformanceMarks
		try{
			var rcg=null; try{ rcg=refs.terminalService._reconnectedTerminalGroups; }catch(e){}
			out.竞速.push({门:'terminalService._reconnectedTerminalGroups',结果:(rcg?判(await race(rcg,3000)):'无该字段（未走远程重连路径）')});
			if(rcg&&(await race(rcg,1000))!==哨){
				try{
					var 组=await rcg; var 实例=[];
					(Array.isArray(组)?组:[]).forEach(function(g){ (g.terminalInstances||[]).forEach(function(it){ 实例.push(it); }); });
					out.重连实例数=实例.length;
					var 待测=实例.slice(0,8).map(function(it,i){ return {i:i,it:it}; });
					out.重连实例回放=[];
					for(var q=0;q<待测.length;q++){
						var one=待测[q];
						var 有字段=false;
						try{ 有字段=!!(one.it._onProcessReplayComplete); }catch(e){}
						out.重连实例回放.push({序:one.i,有回放emitter:有字段,inReplay:形(one.it._inReplay),processState:(function(){ try{ return one.it._processManager.processState; }catch(e){ return '?'; } })()});
					}
				}catch(e){ out.重连实例读取错误=String(e.message||e); }
			}
		}catch(e){ out.重连门异常=String(e.message||e); }
		try{
			var backs=Array.from(refs.terminalInstanceService.getRegisteredBackends());
			out.已注册backend=backs.length;
			for(var i=0;i<backs.length;i++){
				var b=backs[i];
				var auth; try{ auth=(b.remoteAuthority===undefined?'local':String(b.remoteAuthority).slice(0,24)); }catch(e){ auth='?'; }
				var r=null;
				try{ r=await race(Promise.resolve().then(function(){ return b.getPerformanceMarks(); }),5000); }catch(e){ r={__failed__:String(e.message||e)}; }
				out.竞速.push({门:'backend['+auth+'].getPerformanceMarks',结果:判(r)});
				if(b===lb){ W[K+'.localBackend']=lb; }
			}
		}catch(e){ out.backend测异常=String(e.message||e); }

		// ③ 服务级 whenConnected 与本地通道对照（本地通道此前实测是活的，作为对照组）
		try{ out.竞速.push({门:'terminalService.whenConnected',结果:判(await race(refs.terminalService.whenConnected,2000))}); }catch(e){}
		try{ out.竞速.push({门:'terminalService.connectionState',结果:'同步值 '+String(refs.terminalService.connectionState)}); }catch(e){}
		var lps=refs.localPtyService;
		try{ if(lps&&typeof lps.getPerformanceMarks==='function'){ out.竞速.push({门:'localPtyService.getPerformanceMarks（对照组）',结果:判(await race(lps.getPerformanceMarks(),4000))}); } }catch(e){}

		// ④ 直接问实例：能否绕过信任门把进程建出来（只在信任门判定为悬挂时才跑，避免多余副作用）
		try{
			var 信任结果=out.竞速.filter(function(x){ return x.门.indexOf('_ensureWorkspaceTrustedForProcess')>=0; })[0];
			if(信任结果&&信任结果.结果==='悬挂'){
				var pm=探针._processManager;
				out.直接调createProcess=判(await race(pm.createProcess(探针._shellLaunchConfig,80,30),9000));
				out.直调后_ptys=(lb&&lb._ptys)?lb._ptys.size:null;
				out.直调后processState=(function(){ try{ return String(pm.processState); }catch(e){ return '?'; } })();
			}
		}catch(e){ out.直调异常=String(e&&e.stack||e); }

		// 收尾：销毁探针
		var 销毁=0;
		try{
			var 清=(W[K+'.probeList']||[]).slice();
			for(var j=0;j<清.length;j++){ try{ if(清[j]&&typeof 清[j].dispose==='function'){ 清[j].dispose(); 销毁++; } }catch(e){} }
			W[K+'.probeList']=[];
		}catch(e){}
		out.已销毁探针=销毁;
		try{ out.收尾实例数=(refs.terminalService.instances||[]).length; out.收尾本地_ptys=(lb&&lb._ptys)?lb._ptys.size:null; }catch(e){}
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
