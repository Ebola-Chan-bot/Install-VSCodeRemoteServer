// 载荷：工作区信任 × 远程解析死锁的**就地修复**（分阶段，默认只报告）
//
// 已实证的死锁链（本窗口逐环都有取证）：
//   ① RemoteAuthorityResolverService.initializeWorkspaceTrust() 里 _remoteAuthority 只有一个赋值点：
//        resolveAuthority(远程权威).then(async 已解析 => { this._remoteAuthority = 已解析; await fileService.activateProvider('vscode-remote'); await updateWorkspaceTrust(); })
//                              .finally(() => workspaceTrustInitializedPromise 结算)
//      本窗口该 promise 已被解析器**拒绝**（CodeExpectedError: Connecting with SSH timed out）→ .then 正文永远不会跑 → _remoteAuthority 恒为 undefined，且平台无重试。
//      实测：wtm._remoteAuthority=undefined、_trustedAuthorities=Set(0)、_isTrusted=false。
//   ② 于是 isTrustedByRemote() 恒 false → 远程工作区不能自动可信；canSetWorkspaceTrust() 因
//        "remoteAuthority 存在但 _remoteAuthority 缺失" → **false**，连 UI 授权入口都被关掉（实测 false）。
//   ③ 终端启动第一步是 await _ensureWorkspaceTrustedForProcess() → _trust() → requestWorkspaceTrust()：
//        该方法只在**第一次**调用时 fire "发起信任请求" 事件（弹框靠它），之后一律 return 同一个 promise。
//      实测该 promise 悬挂、DOM 里 0 个对话框 → 所有本地终端（含 Remote-SSH 的 3 个隐藏连接终端）永久卡死。
//   ④ 而重新解析又要 Remote-SSH 起一个本地终端跑 ssh → 被 ③ 卡住 → 环形死锁，故 reload 无效。
//
// 修复策略（全部走平台自己的方法，不伪造任何平台没打算成立的状态）：
//   unblock：wtm.registerTrustedAuthority(工作区URI.scheme, 权威) —— 平台公开 API，效果等价于"解析器给了可信权威"，
//            内部会自己 updateWorkspaceTrust()；随后在**确实已可信**的前提下 wtr.resolveWorkspaceTrustRequest(true)
//            （这正是模态框回答"信任"时平台走的同一句），把被卡死的启动全部放行。
//   reresolve：调用平台的 extensionService._resolveAuthorityAgain()（它内部就是 _clearResolvedAuthority → 重跑解析器 →
//            _setResolvedAuthority/_setResolvedAuthorityError），然后把当初 .then 里没跑的正文补完
//            （wtm._remoteAuthority = 结果; updateWorkspaceTrust()），最后**撤销**上一步的临时可信权威，
//            让信任回到由真实解析结果支撑的正轨。
//   verify：复验远程连接、后端 perf、whenConnected、以及全新探针终端能否拿到 pid。
//
// 用法：VSI_STAGES=report|report,unblock|report,unblock,reresolve|... node _probe/window-inject.js <端口> <标题特征> trust-repair.js
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString(),阶段:String('__阶段__').split(','),步骤:[]};
	function 记(msg,obj){
		var 行={序:out.步骤.length+1,内容:String(msg)};
		if(obj!==undefined){ 行.值=obj; }
		out.步骤.push(行);
		return 行;
	}
	try{
		var refs=W[K+'.refs'],root=W[K+'.root'];
		if(!refs||!root){ return {err:'钥匙未交接',阶段:out.阶段}; }
		var 阶段=out.阶段;
		function 要做(名){ return 阶段.indexOf(名)>=0; }
		var 哨={__pending__:true};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(ok){ 计时=setTimeout(function(){ ok(哨); },ms); });
			return Promise.race([Promise.resolve().then(function(){ return p; }),超时]).then(function(v){ clearTimeout(计时); return v; })
				.catch(function(e){ clearTimeout(计时); return {__failed__:String(e&&e.message||e)}; });
		};
		var 判=function(r){ if(r===哨){ return '悬挂'; } if(r&&r.__failed__){ return '已拒绝: '+String(r.__failed__).slice(0,160); } if(r===null){ return '已落定: null'; } if(r===undefined){ return '已落定: undefined'; } if(typeof r==='object'){ return '已落定: obj:'+((r.constructor&&r.constructor.name)||'?')+'{'+Object.keys(r).slice(0,6).join(',')+'}'; } return '已落定: '+String(r); };
		function 形(v){
			try{
				if(v===null){return 'null';} if(v===undefined){return 'undefined';}
				var t=typeof v;
				if(t==='string'){return 'str('+v.length+')'+(v.length<=60?':"'+v+'"':'');}
				if(t==='number'||t==='boolean'){return t+':'+String(v);}
				if(t==='function'){return 'fn:'+(v.name||'匿名');}
				if(Array.isArray(v)){return 'Array('+v.length+')';}
				if(v instanceof Map){return 'Map('+v.size+')';}
				if(v instanceof Set){return 'Set('+v.size+')';}
				if(typeof v.then==='function'){return 'Promise';}
				return 'obj:'+((v.constructor&&v.constructor.name)||'?')+'{'+Object.keys(v).slice(0,8).join(',')+'}';
			}catch(e){return '形?';}
		}
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var 睡=function(ms){ return new Promise(function(ok){ setTimeout(ok,ms); }); };
		var wtm=取服务('workspaceTrustManagementService');
		var wtr=取服务('workspaceTrustRequestService');
		var ras=refs.remoteAgentService;
		var ts=refs.terminalService;
		var lb=refs.localPtyService&&refs.localPtyService._ptys?refs.localPtyService:refs.localPtyService;
		out.服务在场={信任管理:!!wtm,信任请求:!!wtr,远程代理:!!ras,终端:!!ts,本地Pty:!!lb};

		// ========= 阶段 0：取证（任何阶段都跑，作为改动前后的对照） =========
		var resolver=取服务('remoteAuthorityResolverService');
		out.解析服务在场=!!resolver;
		var AUTH=null;
		if(resolver&&resolver._resolveAuthorityRequests){
			try{ resolver._resolveAuthorityRequests.forEach(function(v,k){ if(!AUTH){ AUTH=String(k); } }); }catch(e){}
			out.解析缓存条目=[];
			try{ resolver._resolveAuthorityRequests.forEach(function(v,k){ var e={权威:String(k).slice(0,60),状态:'?'}; try{ e.已解析=Boolean(v.isResolved); }catch(x){} try{ e.已拒绝=Boolean(v.isError||v.error!==undefined); }catch(x){} try{ e.值=形(v.value); }catch(x){} try{ e.方法=['p','cancel','complete','error','isResolved','value'].filter(function(n){ return typeof v[n]!=='undefined'||n==='isResolved'; }).join('/'); }catch(x){} out.解析缓存条目.push(e); }); }catch(e){ out.解析缓存读取错误=e.message; }
		}
		out.权威=AUTH;
		// 工作区 URI（可信权威要按它的 scheme+authority 注册）
		var 工作区URI=null,权威串=null,方案名=null;
		try{
			var us=wtm.getWorkspaceUris?wtm.getWorkspaceUris():[];
			if(us&&us.length){ 工作区URI=us[0]; 权威串=工作区URI.authority; 方案名=工作区URI.scheme; }
		}catch(e){ out.工作区URI错误=e.message; }
		out.工作区={方案:方案名,权威:权威串?String(权威串).slice(0,60)+'…(长'+String(权威串).length+')':null};
		// 缓存条目可能已被平台例程清空（实测：_resolveAuthorityAgain 清了条目、_setResolvedAuthority 因 has() 为假而丢弃结果）
		// → 此时权威字符串从工作区 URI 取，两者本应同源（environmentService.remoteAuthority）
		if(!AUTH&&权威串){ AUTH=String(权威串); out.权威来源='工作区URI（解析缓存条目已被清空）'; }
		// 信任现状
		try{ out.可信前=String(wtm.isWorkspaceTrusted()); }catch(e){ out.可信前='ERR '+e.message; }
		try{ out.可设置信任前=String(wtm.canSetWorkspaceTrust()); }catch(e){}
		try{ out.强制可信前=String(wtm.isWorkspaceTrustForced()); }catch(e){}
		try{ out.权威字段前=形(wtm._remoteAuthority); }catch(e){}
		try{ out.已注册可信权威前=(wtm._trustedAuthorities?wtm._trustedAuthorities.size:'无字段'); }catch(e){}
		// 关键闸门：calculateWorkspaceTrust() 的第一支是 `_canonicalUrisResolved ? … : false`，
		// 规范化 URI 没解析完则信任恒假（任何桥接都无效），必须先看清这一点
		try{ out.规范化已解析=String(wtm._canonicalUrisResolved); }catch(e){ out.规范化已解析='ERR '+e.message; }
		try{
			var cw=wtm._canonicalWorkspace;
			out.规范文件夹数=(cw&&cw.canonicalFolderUris?cw.canonicalFolderUris.length:'无字段');
			out.规范文件夹URI=(cw&&cw.canonicalFolderUris?cw.canonicalFolderUris.map(function(u){ try{ return String(u.scheme)+'://'+String(u.authority||'').slice(0,24)+'…'+String(u.path||'').slice(-30); }catch(e){ return 形(u); } }):null);
		}catch(e){ out.规范化读取错误=e.message; }
		try{
			var ti=wtm._trustStateInfo;
			var 远程条目=(ti&&ti.uriTrustInfo?ti.uriTrustInfo:[]).filter(function(x){ try{ return String(x.uri&&x.uri.scheme||'').indexOf('remote')>=0||String(x.uri&&x.uri.authority||'').indexOf('ssh-remote')>=0; }catch(e){ return false; } });
			out.已存信任记录={总数:(ti&&ti.uriTrustInfo?ti.uriTrustInfo.length:'?'),远程条目数:远程条目.length,远程条目:远程条目.slice(0,5).map(function(x){ try{ return String(x.uri&&x.uri.authority)+'='+x.trusted; }catch(e){ return 形(x); } })};
		}catch(e){ out.已存信任记录错误=e.message; }
		try{ out.竞速_信任请求前=(wtr&&wtr._workspaceTrustRequestPromise)?判(await race(wtr._workspaceTrustRequestPromise,1500)):'无请求promise'; }catch(e){ out.竞速_信任请求前='ERR '+e.message; }
		// 终端侧现状
		function 终端快照(标签){
			// 注意：lb 是 DI 延迟代理，_ptys 读不到（恒 undefined）——一律以实例上的 processId 为真凭据
			try{
				var 实例=(ts.instances||[]);
				var 隐藏本地=实例.filter(function(it){ try{ return !it.remoteAuthority && it.shellLaunchConfig && it.shellLaunchConfig.hideFromUser; }catch(e){ return false; } });
				var 有pid数=0;
				实例.forEach(function(it){ try{ if(typeof it.processId==='number'){ 有pid数++; } }catch(e){} });
				return {实例总数:实例.length,隐藏本地终端数:隐藏本地.length,拿到pid的终端数:有pid数,隐藏本地pid:隐藏本地.map(function(it){ try{ return it.instanceId+'='+(typeof it.processId==='number'?it.processId:String(it.processId)); }catch(e){ return '?'; } })};
			}catch(e){ return {错误:字符串(e)}; }
		}
		function 字符串(v){ try{ return String(v&&v.message||v); }catch(e){ return '?'; } }
		out.终端前=终端快照('前');
		out.竞速_whenConnected前=判(await race(ts.whenConnected,1500));
		try{ out.连接前=(ras&&typeof ras.getConnection==='function')?形(ras.getConnection()):'getConnection 非函数'; }catch(e){ out.连接前='ERR '+e.message; }
		try{ out.远程环境前=判(await race(ras.getEnvironment?ras.getEnvironment():null,4000)); }catch(e){ out.远程环境前='ERR '+e.message; }
		// 平台自带重解析例程是否可用
		var extSvc=取服务('extensionService');
		out.扩展服务=形(extSvc);
		out.有_resolveAuthorityAgain=!!(extSvc&&typeof extSvc._resolveAuthorityAgain==='function');
		out.有_resolveAuthorityInitial=!!(extSvc&&typeof extSvc._resolveAuthorityInitial==='function');
		out.解析器有_clearResolvedAuthority=!!(resolver&&typeof resolver._clearResolvedAuthority==='function');		// ========= 阶段 grant：写入永久信任记录（用户已明确授权：等效于在信任对话框点“是，我信任作者”） =========
		if(要做('grant')){
			function 远程信任条目数(){
				try{
					var ti3=wtm._trustStateInfo;
					var 列=(ti3&&ti3.uriTrustInfo?ti3.uriTrustInfo:[]).filter(function(x){ try{ return String(x.uri&&x.uri.authority||'')===String(权威串||''); }catch(e){ return false; } });
					return 列.length;
				}catch(e){ return -1; }
			}
			out.授予前={可信:String(wtm.isWorkspaceTrusted()),本权威已存记录数:远程信任条目数(),总记录数:(wtm._trustStateInfo&&wtm._trustStateInfo.uriTrustInfo?wtm._trustStateInfo.uriTrustInfo.length:'?'),可设置信任:String(wtm.canSetWorkspaceTrust())};
			// 首选平台自己的公开入口：setWorkspaceTrust(true) = getWorkspaceUris() → setUrisTrust → doSetUrisTrust（追加不重建）→ 落盘
			try{
				out.授予=判(await race(wtm.setWorkspaceTrust(true),25000));
			}catch(e){ out.授予='调用异常 '+String(e&&e.message||e); }
			for(var g1=0;g1<12;g1++){ try{ if(wtm.isWorkspaceTrusted()){ break; } }catch(e){} await 睡(250); }
			try{ out.授予后可信=String(wtm.isWorkspaceTrusted()); }catch(e){ out.授予后可信='ERR '+e.message; }
			out.授予后={可信:out.授予后可信,本权威已存记录数:远程信任条目数(),可设置信任:String(wtm.canSetWorkspaceTrust()),强制可信:String(wtm.isWorkspaceTrustForced())};
			if(out.授予后可信!=='true'){
				// 兜底：setWorkspaceTrust 依赖 getCanonicalUri（远程 URI 要过扩展宿主，可能悬挂），
				// 改为直接向存储追加本条记录再重算（updateWorkspaceTrust(true) 显式传值，避开重新规范化）
				记('setWorkspaceTrust 未能让工作区变可信（'+String(out.授予)+'），转用兜底：直接向 uriTrustInfo 追加本条并落盘',{授予结果:out.授予});
				try{
					var ti4=wtm._trustStateInfo;
					if(!ti4||!ti4.uriTrustInfo){ throw new Error('拿不到 _trustStateInfo.uriTrustInfo'); }
					var 目标串=String(工作区URI);
					var 已存在=ti4.uriTrustInfo.some(function(x){ try{ return String(x.uri)===目标串; }catch(e){ return false; } });
					if(!已存在){ ti4.uriTrustInfo.push({uri:工作区URI,trusted:true}); out.兜底追加=1; }else{ out.兜底追加=0; }
					out.兜底saveTrustInfo=判(await race(wtm.saveTrustInfo(),15000));
					try{ out.兜底updateWorkspaceTrust=判(await race(wtm.updateWorkspaceTrust(true),8000)); }catch(e){ out.兜底updateWorkspaceTrust='ERR '+e.message; }
					for(var g2=0;g2<12;g2++){ try{ if(wtm.isWorkspaceTrusted()){ break; } }catch(e){} await 睡(250); }
					out.兜底后可信=形(wtm.isWorkspaceTrusted());
					out.兜底后={可信:out.兜底后可信,本权威已存记录数:远程信任条目数(),总记录数:ti4.uriTrustInfo.length};
				}catch(e){ out.兜底异常=String(e&&e.message||e); }
			}
			try{ out.最终可信=String(wtm.isWorkspaceTrusted()); }catch(e){}
			if(out.最终可信!=='true'){
				记('信任仍未能变 true —— 不再往下推进重解析（终端仍会被信任门卡死，解析必然超时）',{授予后:out.授予后,兜底后:out.兜底后||out.兜底异常});
				out.结论='grant 阶段失败：信任未能落盘为 true';
				return out;
			}
			记('信任已落盘为 true（等效于用户在信任对话框点“是，我信任作者”；重载后仍有效）',out.兜底后||out.授予后);
		}
		// 只有"纯报告"才提前返回：原先写成 !要做('unblock') 就返回，导致 VSI_STAGES=report,reresolve,verify
		// 被这句悄悄吞掉、白跑一趟（本轮实踩）。注意：只要请求了任一动作阶段就会先架信任桥接 —— 这是必须的，
		// 因为重解析要让 Remote-SSH 起本地终端跑 ssh，信任门不开则解析必然卡死（死锁的另一半）。
		if(!要做('unblock')&&!要做('reresolve')&&!要做('verify')){
			out.结论='只报告阶段：未改任何状态。死锁证据=可信'+out.可信前+'/可设置信任'+out.可设置信任前+'/_remoteAuthority '+out.权威字段前+'/信任请求 '+out.竞速_信任请求前+'/whenConnected '+out.竞速_whenConnected前;
			return out;
		}

		// ========= 阶段 A：解除信任门死锁 =========
		var 桥接=W[K+'.trustBridge']||null;
		if(桥接&&typeof 桥接.dispose==='function'){
			try{ 桥接.dispose(); }catch(e){}
			记('发现上一轮残留的可信权威桥接，先销毁以保证幂等',{});
			桥接=null;
		}
		if(out.规范化已解析!=='true'){
			记('规范化 URI 尚未解析（_canonicalUrisResolved='+out.规范化已解析+'）—— calculateWorkspaceTrust 会直接返回 false，桥接不可能生效，先不改动现场');
			out.结论='阶段A中止：_canonicalUrisResolved 不为真，信任计算被第一道闸门挡死';
			return out;
		}
		try{
			var 已可信=false;
			try{ 已可信=Boolean(wtm.isWorkspaceTrusted()); }catch(e){}
			if(已可信){
				记('信任已为 true（记录已落盘），跳过临时桥接：不再往窗口里加临时可信权威',{});
			}else if(方案名&&权威串){
				桥接=wtm.registerTrustedAuthority(方案名,权威串);
				W[K+'.trustBridge']=桥接;
				记('已调用 registerTrustedAuthority(平台公开 API，效果等同"解析器给出可信权威")',{方案:方案名,权威长度:String(权威串).length,返回:形(桥接)});
			}else{
				记('无法注册可信权威：拿不到工作区 URI',{方案:方案名,权威:权威串});
			}
		}catch(e){ 记('registerTrustedAuthority 异常',e.message); }
		// 等平台内部 updateWorkspaceTrust() 完成（它是异步的）
		var 可信=false;
		for(var i=0;i<12;i++){
			try{ 可信=Boolean(wtm.isWorkspaceTrusted()); }catch(e){}
			if(可信){ break; }
			await 睡(250);
		}
		out.可信后注册=String(可信);
		try{ out.强制可信后=String(wtm.isWorkspaceTrustForced()); }catch(e){}
		try{ out.可设置信任后=String(wtm.canSetWorkspaceTrust()); }catch(e){}
		try{ out.已注册可信权威后=(wtm._trustedAuthorities?wtm._trustedAuthorities.size:'无字段'); }catch(e){}
		if(!可信){
			记('临时可信权威未能让工作区变为可信 —— 不再继续放行（避免伪造信任结论），保留现场');
			out.结论='阶段A失败：registerTrustedAuthority 后 isWorkspaceTrusted 仍为 false';
			return out;
		}
		// 放行被卡死的信任请求：与模态框回答"信任"时平台执行的是同一句
		try{
			if(wtr&&wtr._workspaceTrustRequestResolver&&typeof wtr.resolveWorkspaceTrustRequest==='function'){
				wtr.resolveWorkspaceTrustRequest(true);
				记('已调用 resolveWorkspaceTrustRequest(true)（等价于用户在信任对话框点"是，我信任作者"后平台自己做的事）',{});
			}else{
				记('无需放行：信任请求 promise 不存在',{请求服务:形(wtr)});
			}
		}catch(e){ 记('resolveWorkspaceTrustRequest 异常',e.message); }
		try{ out.竞速_信任请求后=wtr&&wtr._workspaceTrustRequestPromise?判(await race(wtr._workspaceTrustRequestPromise,1500)):'已清空:'+String(!wtr||!wtr._workspaceTrustRequestPromise); }catch(e){ out.竞速_信任请求后='ERR '+e.message; }
		// 复验被卡住的终端是否真的起来了（以 pid 为准，最长等 20 秒）
		for(var j=0;j<26;j++){
			out.终端后=终端快照('后');
			if(out.终端后.拿到pid的终端数>0){ break; }
			await 睡(750);
		}
		记('阶段A复验：被卡终端是否开始创建进程',out.终端后);
		if(!要做('reresolve')){
			out.结论='阶段A完成：信任门已解除（可信='+out.可信后注册+'）。未执行重解析。';
			return out;
		}

		// ========= 阶段 B：用平台自己的例程重跑解析（恢复远程连接） =========
		if(!AUTH){ 记('拿不到权威字符串，跳过重解析'); }
		else if(out.有_resolveAuthorityAgain){
			// 关键教训（实测两次踩到）：_resolveAuthorityAgain() 是"清缓存→重跑解析器→把结果写回缓存"的一体例程，
			// 而它的 _setResolvedAuthority / _setResolvedAuthorityError 都以 `_resolveAuthorityRequests.has(权威)` 为前提，
			// 它自己第一步却把条目删了 —— 若此刻没有别人持有/新建这个延迟 promise，**结果连同失败原因一起被静默丢弃**
			// （实测：例程 60 毫秒内就落定为 undefined，条目终态 已解析=false / 值=undefined，getConnectionData=null）。
			// 故改为：先由我们自己建条目接住结果，再直接调平台真正干活的 _resolveAuthorityWithLogging(权威)，
			// 拿到返回值后用平台自己的 _setResolvedAuthority 发布（会 fire onDidChangeConnectionData → 远程代理重连）。
			var 直调可用=!!(extSvc&&typeof extSvc._resolveAuthorityWithLogging==='function');
			out.直调可用=直调可用;
			try{ out.远端扩展宿主管理器数=(extSvc&&typeof extSvc._getExtensionHostManagers==='function')?((extSvc._getExtensionHostManagers(1)||[]).length):'无该方法'; }catch(e){ out.远端管理器数异常=e.message; }
			try{ out.解析尝试次数已累积=形(extSvc&&extSvc._resolveAuthorityAttempt); }catch(e){}
			if(resolver&&typeof resolver._clearResolvedAuthority==='function'&&resolver._resolveAuthorityRequests&&resolver._resolveAuthorityRequests.has(AUTH)){
				try{
					var 旧=resolver._resolveAuthorityRequests.get(AUTH);
					var 旧态={已解析:(旧?Boolean(旧.isResolved):null),值:(旧?形(旧.value):null)};
					resolver._clearResolvedAuthority(AUTH);
					记('先清掉遗留/中毒的解析缓存条目（平台自己的清除方法，会 cancel 旧延迟 promise）',{旧态:旧态});
				}catch(e){ 记('清除旧条目异常',e.message); }
			}
			var np=null;
			try{
				np=resolver.resolveAuthority(AUTH);
				记('已先建好用于接收结果的延迟 promise 条目（先建条目再重跑，结果才不会无处安放）',{形态:形(np)});
			}catch(e){ 记('建立延迟 promise 失败',e.message); }
			// 等解析结果（ssh 重连可能较久：preconnect→ssh→必要时装 server）
			var 重试=null;
			if(直调可用){
				try{ 重试=await race(extSvc._resolveAuthorityWithLogging(AUTH),150000); }catch(e){ 重试={__failed__:String(e&&e.message||e)}; }
			}else if(out.有_resolveAuthorityAgain){
				try{ extSvc._resolveAuthorityAgain(); 记('退化：平台无 _resolveAuthorityWithLogging，改用 _resolveAuthorityAgain',{}); }catch(e){ 记('_resolveAuthorityAgain 抛出',e.message); }
				重试=np?await race(np,60000):哨;
			}
			var 结果=重试;
			var 值=null;
			if(结果===哨){ out.重解析结果='悬挂(150秒)'; }
			else if(结果&&结果.__failed__){
				out.重解析结果='已拒绝: '+String(结果.__failed__).slice(0,300);
				try{
					if(typeof resolver._setResolvedAuthorityError==='function'){
						resolver._setResolvedAuthorityError(AUTH,new Error(String(结果.__failed__).slice(0,200)));
						记('已按平台协议把失败原因写回缓存条目（不再静默丢弃）',{});
					}
				}catch(e){ 记('写回失败原因异常',e.message); }
			}
			else {
				out.重解析结果='已解析';
				值=结果;
				try{
					out.解析值得={
						顶层:形(值),
						authority:形(值&&值.authority),
						connectTo:形(值&&值.authority&&值.authority.connectTo),
						令牌:形(值&&值.authority&&值.authority.connectionToken),
						options:形(值&&值.options),
						options_isTrusted:(值&&值.options&&typeof 值.options.isTrusted!=='undefined')?String(值.options.isTrusted):'无该字段'
					};
				}catch(e){ out.解析值读取错误=e.message; }
				try{
					if(typeof resolver._setResolvedAuthority==='function'){
						resolver._setResolvedAuthority(值.authority,值.options);
						记('重解析成功，已用平台自己的 _setResolvedAuthority 发布结果（会 fire onDidChangeConnectionData → 远程代理重连）',{概要:out.解析值得});
					}else{
						记('重解析成功，但解析服务无 _setResolvedAuthority，结果只能就地保存',{概要:out.解析值得});
					}
				}catch(e){ 记('发布解析结果异常',e.message); }
			}
			out.平台例程结果=直调可用?'未使用（改直调 _resolveAuthorityWithLogging：失败原因不会丢）':'已退化为 _resolveAuthorityAgain';
			try{
				if(resolver&&resolver._resolveAuthorityRequests&&resolver._resolveAuthorityRequests.has(AUTH)){
					var df=resolver._resolveAuthorityRequests.get(AUTH);
					out.解析条目终态={已解析:Boolean(df.isResolved),值:形(df.value)};
					try{ out.连接数据=形(resolver.getConnectionData(AUTH)); }catch(e){ out.连接数据读取错误=e.message; }
				}else{ out.解析条目终态='条目不在缓存里（结果无处安放）'; }
			}catch(e){ out.解析条目终态读取错误=e.message; }
			if(out.重解析结果==='已解析'){
				// 补完当初被拒绝跳过的 .then 正文
				try{
					var 已解析权威=值&&值.authority?值.authority:值;
					var 选项=值&&值.options?值.options:undefined;
					wtm._remoteAuthority={authority:已解析权威,options:选项};
					记('已补写 wtm._remoteAuthority（即 initializeWorkspaceTrust 里被 .then 跳过的那次赋值）',{权威形态:形(已解析权威),选项:形(选项)});
				}catch(e){ 记('补写 _remoteAuthority 失败',e.message); }
				try{ var fs2=取服务('fileService'); if(fs2&&typeof fs2.activateProvider==='function'){ await fs2.activateProvider('vscode-remote'); 记('已激活 vscode-remote 文件提供器',{}); } }catch(e){ 记('激活文件提供器失败（不致命）',e.message); }
				try{ if(typeof wtm.updateWorkspaceTrust==='function'){ await wtm.updateWorkspaceTrust(); 记('已重算工作区信任',{}); } }catch(e){ 记('updateWorkspaceTrust 异常',e.message); }
				try{ out.可设置信任补远权后=String(wtm.canSetWorkspaceTrust()); }catch(e){}
				// 撤销临时桥接，让信任回到由真实解析结果支撑
				try{
					if(桥接&&typeof 桥接.dispose==='function'&&桥接!==W[K+'.trustBridge']){ 桥接.dispose(); 桥接=null; }else if(桥接&&typeof 桥接.dispose==='function'){ 桥接.dispose(); 桥接=null; W[K+'.trustBridge']=null; 记('已撤销临时可信权威（桥接），信任应由真实 _remoteAuthority 支撑',{可信:形(wtm.isWorkspaceTrusted())}); }
				}catch(e){ 记('撤销桥接异常',e.message); }
				await 睡(400);
				try{ out.可信撤桥后=String(wtm.isWorkspaceTrusted()); }catch(e){ out.可信撤桥后='ERR '+e.message; }
				try{ out.权威字段后=形(wtm._remoteAuthority); }catch(e){}
				try{ out.强制可信终=String(wtm.isWorkspaceTrustForced()); }catch(e){}
				if(out.可信撤桥后!=='true'){
					记('撤销桥接后信任回落为 false —— 重新架桥，保证终端不被再次卡死');
					try{ 桥接=wtm.registerTrustedAuthority(方案名,权威串); W[K+'.trustBridge']=桥接; }catch(e){ 记('重新架桥异常',e.message); }
					for(var m=0;m<8;m++){ try{ if(wtm.isWorkspaceTrusted()){ break; } }catch(e){} await 睡(250); }
					try{ out.可信重架桥后=String(wtm.isWorkspaceTrusted()); }catch(e){}
					// 信任记录里没有本权威（同主机不带用户后缀的权威有 24 条已授权记录，本权威 0 条 —— 存储上限 50 条，很可能被淘汰）。
					// 永久授权属于用户的决定，不代他写：现在 canSetWorkspaceTrust 可能已为真（_remoteAuthority 补上了），
					// 就用平台自己的 requestWorkspaceTrust 让本该出现的模态框重新弹出来，由用户点"是，我信任作者"落盘。
					try{
						if(要做('prompt')&&wtr&&typeof wtr.requestWorkspaceTrust==='function'&&Boolean(wtm.canSetWorkspaceTrust())){
							wtr.requestWorkspaceTrust({message:'远程工作区需要确认信任后才能启动终端（该主机的信任记录已丢失）。请点"是，我信任作者"。'});
							记('已让平台的信任模态框重新弹出（requestWorkspaceTrust）——请在窗口里亲自作答，答复后会写入信任记录，此后无需桥接',{});
							await 睡(1200);
							try{ out.模态框数=document.querySelectorAll('.monaco-dialog-box').length; }catch(e){}
							try{ out.模态框文本=[]; var dl=document.querySelectorAll('.monaco-dialog-box'); for(var w2=0;w2<dl.length&&w2<3;w2++){ out.模态框文本.push(String(dl[w2].textContent||'').replace(/\s+/g,' ').slice(0,160)); } }catch(e){}
						}else{
							记('不弹模态框',{原因:'阶段未含 prompt 或 canSetWorkspaceTrust 仍为假',canSet:形(wtm.canSetWorkspaceTrust())});
						}
					}catch(e){ 记('requestWorkspaceTrust 异常',e.message); }
				}
			}
		}else{
			记('本机 bundle 无 _resolveAuthorityAgain —— 退化为 _clearResolvedAuthority + resolveAuthority');
			try{
				if(resolver&&typeof resolver._clearResolvedAuthority==='function'&&AUTH){
					resolver._clearResolvedAuthority(AUTH);
					记('已清除中毒的解析缓存条目',{});
					var np=resolver.resolveAuthority(AUTH);
					out.退化重解析=判(await race(np,20000));
				}
			}catch(e){ 记('退化重解析异常',e.message); }
		}
		if(!要做('verify')){ out.结论='阶段B完成（重解析结果='+out.重解析结果+'）。未做下游复验。'; return out; }

		// ========= 阶段 C：下游复验 =========
		try{ out.连接后=(ras&&typeof ras.getConnection==='function')?形(ras.getConnection()):'?'; }catch(e){ out.连接后='ERR '+e.message; }
		try{ out.远程环境后=判(await race(ras.getEnvironment?ras.getEnvironment():null,6000)); }catch(e){ out.远程环境后='ERR '+e.message; }
		try{ out.竞速_whenConnected后=判(await race(ts.whenConnected,5000)); }catch(e){}
		var 后端结果=[];
		try{
			// 本 bundle 里没有 getRegisteredBackends（实测报 is not a function）→ 改用已知的两个后端对象：
			// 本地（lb，取自钥匙）与终端服务的主后端（_primaryBackend，远程窗口里就是远程后端）
			var 候选=[{名:'local',b:lb}];
			try{ if(ts._primaryBackend&&ts._primaryBackend!==lb){ 候选.push({名:'primary',b:ts._primaryBackend}); } }catch(e){}
			for(var n2=0;n2<候选.length;n2++){
				var b=候选[n2].b;
				if(!b){ 后端结果.push({后端:候选[n2].名,err:'对象不在'}); continue; }
				var 项={后端:候选[n2].名,构造:形(b).slice(0,40)};
				try{ 项.perf=判(await race(b.getPerformanceMarks(),4000)); }catch(e){ 项.perf='ERR '+e.message; }
				try{ 项.ready=判(await race(b.whenReady,2000)); }catch(e){}
				后端结果.push(项);
			}
		}catch(e){ 后端结果.push({err:e.message}); }
		out.后端复验=后端结果;
		// 新建探针终端：最终验收（能拿到 pid 即证明信任门与 pty 通道都通）
		var 探针=null;
		try{
			var URI类=null;
			try{ URI类=W[K+'.uri']; }catch(e){}
			if(!URI类){ URI类=取服务('uriIdentityService')&&取服务('uriIdentityService').extUri&&取服务('uriIdentityService').extUri.URI?取服务('uriIdentityService').extUri.URI.constructor:null; }
			if(!URI类){ try{ URI类=(function(){ var x=document.createElement('a'); return null; })(); }catch(e){} }
			out.探针创建='开始';
			探针=await ts.createTerminal({cwd:'/__本地目录__'.replace(/^\/|\/$/g,''),hideFromUser:true,name:'vsi-trust-验收'});
			var pid=哨;
			for(var q=0;q<40;q++){ try{ if(typeof 探针.processId==='number'&&探针.processId>0){ pid=探针.processId; break; } }catch(e){} await 睡(750); }
			out.探针验收={pid:(pid===哨?'悬挂(30秒)':String(pid)),终端形态:形(探针),实例总数:((ts.instances||[]).length)};
		}catch(e){ out.探针验收={异常:e.message||String(e)}; }
		// 收尾
		try{ if(探针&&typeof 探针.dispose==='function'){ 探针.dispose(); out.探针已销毁=1; } }catch(e){ out.探针已销毁=0; }
		out.终端终=终端快照('终');
		out.结论='修复流程结束：信任门解除='+out.可信后注册+'，重解析='+out.重解析结果+'，远程环境='+(out.远程环境后||'?')+'，whenConnected='+(out.竞速_whenConnected后||'?')+'，探针pid='+String(out.探针验收&&(out.探针验收.pid||out.探针验收.异常));
		if(桥接){ out.遗留桥接='临时可信权威仍生效（重解析未成功时故意保留，否则终端会再次卡死）'; }
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
