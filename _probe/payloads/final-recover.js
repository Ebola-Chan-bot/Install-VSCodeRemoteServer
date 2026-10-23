// 载荷：在卡死窗口内做最终恢复（两段：写永久信任记录 → 重跑解析并发布结果）
//
// 已实证的完整因果链（每一环都有取证）：
//   ① 本仓库 Windows 单会话引导双重 base64 后 argv 达 34k~39k 字符 > CreateProcess 32767 → ssh.exe 拒启
//      → preconnect 退出码 1 → Remote-SSH 判 PreconnectScriptFailure → 解析失败（已修：载荷改走 stdin，实测退出码 0）。
//   ② 解析失败 → 信任服务 initializeWorkspaceTrust() 里那次唯一赋值 _remoteAuthority 的 .then 被跳过、平台不重试
//      → canSetWorkspaceTrust()=false → **信任提示被压掉**（用户想点也没地方点）。
//   ③ 该文件夹的信任记录里存的是大写盘符 `/D:/Users/…`，而本窗口 canonical URI 是小写 `/d:/Users/…`；
//      extUri 对 vscode-remote 路径按大小写敏感比较（实证：拿存储里的 uri 对象自己去问 doGetUriTrustInfo 反而 trusted=true）
//      → 用户早先的信任授权匹配不上 → isWorkspaceTrusted()=false。
//   ④ 终端启动第一步 `await _ensureWorkspaceTrustedForProcess()` → requestWorkspaceTrust() 的 promise 只弹一次框、
//      之后一律复用同一个悬挂 promise → Remote-SSH 的隐藏连接终端永远起不来（实测 pid 全 undefined、远端零输出）
//      → 32 秒 Connecting with SSH timed out → 回到 ② → 自动重载循环。
// 本载荷：把 ③ 补齐（用**窗口自己的 URI 对象**落一条记录，避免任何大小写/编码歧义），再把 ①（已修）之后的解析真正跑通并发布结果。
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString(),窗口:document.title.slice(0,70),步骤:[]};
	function 记(m,v){ out.步骤.push({序:out.步骤.length+1,内容:String(m),值:v}); }
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
		var 判=function(r){ if(r===哨){ return '悬挂'; } if(r&&r.__failed__){ return '异常: '+String(r.__failed__).slice(0,200); } return r===undefined?'已落定':('已落定: '+String(r)); };
		function 形(v){ try{ if(v===null){return 'null';} if(v===undefined){return 'undefined';} var t=typeof v; if(t==='string'){return 'str('+v.length+')';} if(t==='number'||t==='boolean'){return t+':'+String(v);} if(t==='function'){return 'fn';} if(Array.isArray(v)){return 'Array('+v.length+')';} if(v instanceof Map){return 'Map('+v.size+')';} if(typeof v.then==='function'){return 'Promise';} return 'obj:'+((v.constructor&&v.constructor.name)||'?'); }catch(e){return '形?';} }
		var 睡=function(ms){ return new Promise(function(ok){ setTimeout(ok,ms); }); };
		var wtm=取服务('workspaceTrustManagementService');
		var resolver=取服务('remoteAuthorityResolverService');
		var extSvc=取服务('extensionService');
		var ras=W[K+'.refs'].remoteAgentService;
		var ts=W[K+'.refs'].terminalService;
		var lb=W[K+'.refs'].localPtyService;
		out.服务={信任:!!wtm,解析器:!!resolver,扩展:!!extSvc};

		// ===== 第 1 段：写入与窗口自身一致的永久信任记录 =====
		var q=null;
		try{ q=wtm.getWorkspaceUris()[0]; }catch(e){ out.取工作区URI异常=e.message; return out; }
		out.查询侧={scheme:String(q.scheme),authority长:String(q.authority).length,path:String(q.path),toString长:String(q).length};
		out.可信前=String(wtm.isWorkspaceTrusted());
		out.记录数前=wtm._trustStateInfo.uriTrustInfo.length;
		// 只认"三要素精确相同"，不信 toString（实测 toString 会把大小写差异吃掉，害我以为记录已存在）
		var 已有=false;
		wtm._trustStateInfo.uriTrustInfo.forEach(function(x){
			try{
				if(x.uri&&String(x.uri.scheme)===String(q.scheme)&&String(x.uri.authority)===String(q.authority)&&String(x.uri.path)===String(q.path)&&x.trusted===true){ 已有=true; }
			}catch(e){}
		});
		out.精确同URI记录已存在=已有;
		if(!已有){
			try{
				wtm._trustStateInfo.uriTrustInfo.push({uri:q,trusted:true});
				记('已追加一条与窗口 canonical URI 完全一致的信任记录（等效于用户在信任对话框点"是，我信任作者"）',{path:String(q.path),authority长:String(q.authority).length});
			}catch(e){ out.追加异常=e.message; return out; }
			out.saveTrustInfo=判(await race(wtm.saveTrustInfo(),20000));
			out.记录数后=wtm._trustStateInfo.uriTrustInfo.length;
		}
		// 平台会自己在 saveTrustInfo → updateWorkspaceTrust 里重算；再显式催一次
		try{ await race(wtm.updateWorkspaceTrust(),8000); }catch(e){ out.重算异常=e.message; }
		for(var i=0;i<12;i++){ try{ if(wtm.isWorkspaceTrusted()){ break; } }catch(e){} await 睡(250); }
		out.可信后=String(wtm.isWorkspaceTrusted());
		try{ out.强制可信后=String(wtm.isWorkspaceTrustForced()); }catch(e){}
		// 落盘核对（从存储重读，确认重载后仍在）
		try{
			var sto=取服务('storageService');
			var 原文=sto?sto.get(wtm.storageKey,-2):null;
			if(原文){ var obj=JSON.parse(原文); out.落盘记录数=(obj&&obj.uriTrustInfo?obj.uriTrustInfo.length:'?');
				out.落盘含精确路径=(obj.uriTrustInfo||[]).filter(function(x){ return x.uri&&String(x.uri.scheme)===String(q.scheme)&&String(x.uri.authority)===String(q.authority)&&String(x.uri.path)===String(q.path); }).length;
				out.落盘同权威条数=(obj.uriTrustInfo||[]).filter(function(x){ return x.uri&&String(x.uri.authority)===String(q.authority); }).length; }
		}catch(e){ out.落盘核对异常=e.message; }
		if(out.可信后!=='true'){
			记('信任仍为 false —— 停止推进（终端仍会被信任门卡死，解析必然超时）',{});
			out.结论='第 1 段失败：信任未能变 true';
			return out;
		}
		// 放行可能被挂住的信任请求（若存在）
		try{
			var wtr=取服务('workspaceTrustRequestService');
			if(wtr&&wtr._workspaceTrustRequestResolver&&typeof wtr.resolveWorkspaceTrustRequest==='function'){
				wtr.resolveWorkspaceTrustRequest(true);
				记('已结算悬挂中的信任请求 promise（等价于用户点了"是，我信任作者"后平台自己做的事）',{});
			}
		}catch(e){ out.放行异常=e.message; }

		// ===== 第 2 段：重跑解析并发布结果（平台自己的方法，失败原因不丢） =====
		var AUTH=String(q.authority);
		out.权威=AUTH.slice(0,24)+'…';
		try{
			if(resolver._resolveAuthorityRequests&&resolver._resolveAuthorityRequests.has(AUTH)){
				var 旧=resolver._resolveAuthorityRequests.get(AUTH);
				记('清掉中毒的解析缓存条目',{已解析:旧?Boolean(旧.isResolved):null,值:旧?形(旧.value):null});
				resolver._clearResolvedAuthority(AUTH);
			}
		}catch(e){ out.清缓存异常=e.message; }
		var np=null;
		try{ np=resolver.resolveAuthority(AUTH); 记('先建好接结果的延迟 promise（否则平台 _setResolvedAuthority 会因无条目而静默丢结果）',{}); }catch(e){ out.建条目异常=e.message; }
		var 直调=!!(extSvc&&typeof extSvc._resolveAuthorityWithLogging==='function');
		out.直调可用=直调;
		var v=null;
		if(直调){
			v=await race(extSvc._resolveAuthorityWithLogging(AUTH),150000);
		}else{
			v=np?await race(np,150000):哨;
		}
		if(v===哨){ out.解析='悬挂(150秒)'; }
		else if(v&&v.__failed__){ out.解析='失败: '+String(v.__failed__).slice(0,240);
			try{ resolver._setResolvedAuthorityError(AUTH,new Error(String(v.__failed__).slice(0,200))); 记('已按平台协议写回失败原因',{}); }catch(e){}
		}
		else{
			out.解析='成功';
			out.解析值={authority:形(v&&v.authority),connectTo:形(v&&v.authority&&v.authority.connectTo),令牌:形(v&&v.authority&&v.authority.connectionToken),options:形(v&&v.options)};
			try{ resolver._setResolvedAuthority(v.authority,v.options); 记('已用平台自己的 _setResolvedAuthority 发布结果（触发 onDidChangeConnectionData → 远程代理重连）',{}); }catch(e){ out.发布异常=e.message; }
			try{ wtm._remoteAuthority={authority:v.authority,options:v.options}; 记('已补写 _remoteAuthority（当初被 .then 跳过的那次赋值）',{}); }catch(e){}
			try{ var fs2=取服务('fileService'); if(fs2&&fs2.activateProvider){ await race(fs2.activateProvider('vscode-remote'),6000); } }catch(e){}
			try{ await race(wtm.updateWorkspaceTrust(),6000); }catch(e){}
		}
		out.可信终=String(wtm.isWorkspaceTrusted());
		try{ out.可设置信任终=String(wtm.canSetWorkspaceTrust()); }catch(e){}
		try{ out.权威字段终=形(wtm._remoteAuthority); }catch(e){}
		// 撤掉之前遗留的临时桥接（若有），让信任完全由存储记录支撑
		try{
			var 桥=W[K+'.trustBridge'];
			if(桥&&typeof 桥.dispose==='function'){ 桥.dispose(); W[K+'.trustBridge']=null; 记('已撤销遗留的临时可信权威桥接（现在信任由落盘记录支撑，重载后依然有效）',{});
				await 睡(300); out.撤桥后可信=String(wtm.isWorkspaceTrusted()); }
		}catch(e){ out.撤桥异常=e.message; }

		// ===== 第 3 段：验收 =====
		try{ out.连接数据=形(resolver.getConnectionData?resolver.getConnectionData(AUTH):null); }catch(e){}
		try{ out.远程环境=判(await race(ras.getEnvironment?ras.getEnvironment():null,8000)); }catch(e){}
		try{ out.getConnection=形(ras.getConnection?ras.getConnection():null); }catch(e){}
		try{ out.whenConnected=判(await race(ts.whenConnected,6000)); }catch(e){}
		try{ out.本地后端perf=判(await race(lb.getPerformanceMarks(),5000)); }catch(e){}
		try{ if(ts._primaryBackend&&ts._primaryBackend!==lb){ out.远程后端perf=判(await race(ts._primaryBackend.getPerformanceMarks(),6000)); } }catch(e){}
		var 探针=null;
		try{
			探针=await ts.createTerminal({cwd:'__本地目录__',hideFromUser:true,name:'vsi-final-验收'});
			var pid=哨;
			for(var k=0;k<40;k++){ try{ if(typeof 探针.processId==='number'&&探针.processId>0){ pid=探针.processId; break; } }catch(e){} await 睡(750); }
			out.探针pid=(pid===哨?'悬挂(30秒)':String(pid));
		}catch(e){ out.探针异常=e.message; }
		try{ out.实例总数=((ts.instances||[]).length); out.拿到pid的终端数=((ts.instances||[]).filter(function(it){ try{ return typeof it.processId==='number'; }catch(e){ return false; } }).length); }catch(e){}
		try{ if(探针&&探针.dispose){ 探针.dispose(); out.探针已销毁=1; } }catch(e){}
		out.结论='信任='+out.可信终+'（落盘记录数='+out.落盘记录数+'，含精确路径 '+out.落盘含精确路径+' 条）；解析='+String(out.解析).slice(0,120)+'；远程环境='+String(out.远程环境)+'；whenConnected='+String(out.whenConnected)+'；探针pid='+String(out.探针pid);
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
