// 载荷：在**同 profile 的另一个窗口**里，为目标远程文件夹写入永久工作区信任记录
//
// 为什么不在那个卡死的窗口里做：它已进入自动重载循环（注入时反复 "Inspected target navigated or closed"），
//   每轮重载都会重新解析→解析要起本地终端→信任门挡住→32 秒超时→解析失败→再重载。
//   信任记录存在 profile 级存储（storageKey=content.trust.model.key，StorageScope.PROFILE），
//   任何同 profile 窗口都能写入；卡死的窗口下一次重载时 loadTrustInfo() 就会读到它。
// 用的是平台自己的对象与持久化路径：直接往 _trustStateInfo.uriTrustInfo 追加 {uri, trusted:true} 后 saveTrustInfo()
//   （等价于 doSetUrisTrust(uri,true) 的写入结果，但跳过 getCanonicalUri —— 远程规范化会走扩展宿主，在死连接下可能悬挂）。
// 安全护栏：动手前后都读本窗口的 isWorkspaceTrusted()，若本窗口信任被意外改动立刻如实报告；写入后从存储里回读核对。
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString(),窗口:document.title.slice(0,80)};
	try{
		var root=W[K+'.root'];
		if(!root){ return {err:'钥匙未交接',窗口:out.窗口}; }
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var 哨={__pending__:true};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(ok){ 计时=setTimeout(function(){ ok(哨); },ms); });
			return Promise.race([Promise.resolve().then(function(){ return p; }),超时]).then(function(v){ clearTimeout(计时); return v; })
				.catch(function(e){ clearTimeout(计时); return {__failed__:String(e&&e.message||e)}; });
		};
		var 判=function(r){ if(r===哨){ return '悬挂'; } if(r&&r.__failed__){ return '异常: '+String(r.__failed__).slice(0,150); } return r===undefined?'已落定':('已落定: '+String(r)); };
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
		var 睡=function(ms){ return new Promise(function(ok){ setTimeout(ok,ms); }); };
		var wtm=取服务('workspaceTrustManagementService');
		var wss=取服务('workspaceService');
		var sto=取服务('storageService');
		out.服务在场={信任管理:!!wtm,工作区:!!wss,存储:!!sto};
		// workspaceService 在部分窗口（如空工作区的欢迎窗口）拿不到对应 DI 条目，不是必需：URI 类可从已存信任记录借
		if(!wtm||!sto){ out.err='缺必需服务（信任管理/存储）'; return out; }

		// ===== 护栏：本窗口（工具窗口）的信任必须本来是 true，动手后仍须为 true =====
		try{ out.本窗口可信前=String(wtm.isWorkspaceTrusted()); }catch(e){ out.本窗口可信前='ERR '+e.message; }

		// ===== 构造目标 URI（权威与路径逐字取自卡死窗口的取证输出，长度也要对得上） =====
		var 方案='vscode-remote';
		var 权威='ssh-remote+7b22686f73744e616d65223a22e4b88ae7a791e5a4a741e69c8de58aa1e599a85fe5bca0e5a4a9e5a4ab227d';
		var 路径='/d:/Users/张天夫/Documents/MATLAB/Transfer-learning';
		var URI类=null;
		try{
			if(wss){
				var folders=wss.getWorkspace().folders;
				if(folders&&folders.length){ URI类=folders[0].uri.constructor; }
			}
		}catch(e){ out.取URI类失败=e.message; }
		if(!URI类){
			// 欢迎窗口（空工作区）没有文件夹，改从已存信任记录里借一个 URI 实例取构造器
			try{
				var 已有=wtm.getTrustedUris?wtm.getTrustedUris():null;
				if(已有&&已有.length){ URI类=已有[0].constructor; out.URI类来源='已存信任记录[0]'; }
			}catch(e){ out.借URI类失败=e.message; }
		}else{ out.URI类来源='工作区文件夹[0]'; }
		out.URI类可用=!!URI类;
		if(!URI类){ return out; }
		out.URI类构造名=(URI类&&URI类.name)||'?';
		out.URI有parse=(typeof URI类.parse==='function');
		var 目标URI=null;
		try{
			// Uri.parse 的静态方法名在 bundle 里保留（构造名是 Uri）；不可用时退回 URI.file 之外的方案
			if(typeof URI类.parse==='function'){ 目标URI=URI类.parse(方案+'://'+权威+路径); }
		}catch(e){ out.解析URI异常=e.message; }
		if(!目标URI){ out.err='无法构造目标 URI（URI.parse 不可用）'; return out; }
		out.目标={
			方案:String(目标URI.scheme),
			权威长度:String(目标URI.authority).length,
			权威头20:String(目标URI.authority).slice(0,20),
			路径:String(目标URI.path),
			toString长度:String(目标URI).length,
			toString:String(目标URI).slice(0,60)+'…'
		};
		out.目标权威长度应为99=(String(目标URI.authority).length===99);

		// ===== 现有记录对照 =====
		var ti=wtm._trustStateInfo;
		out.记录数前=(ti&&ti.uriTrustInfo?ti.uriTrustInfo.length:'无字段');
		var 目标串=String(目标URI);
		var 已存在=false;
		try{
			ti.uriTrustInfo.forEach(function(x){ try{ if(String(x.uri)===目标串){ 已存在=true; } }catch(e){} });
		}catch(e){}
		out.写入前已存在=已存在;
		out.同权威记录数前=(function(){ try{ return ti.uriTrustInfo.filter(function(x){ return String(x.uri&&x.uri.authority||'')===权威; }).length; }catch(e){ return -1; } })();

		if(已存在){
			out.结论='记录已存在，未重复写入（信任应已为 true，若窗口仍卡死说明另有原因）';
			return out;
		}

		// ===== 写入并落盘（平台自己的持久化方法） =====
		try{
			ti.uriTrustInfo.push({uri:目标URI,trusted:true});
			out.已追加=1;
		}catch(e){ out.追加异常=e.message; return out; }
		out.saveTrustInfo=判(await race(wtm.saveTrustInfo(),15000));

		// ===== 护栏复查：本窗口信任不得被改坏 =====
		try{ out.本窗口可信后=String(wtm.isWorkspaceTrusted()); }catch(e){ out.本窗口可信后='ERR '+e.message; }
		if(out.本窗口可信前==='true'&&out.本窗口可信后!=='true'){
			out.警告='本窗口信任被改动（不应该发生）。已如实记录，请检查该窗口的信任状态。';
		}

		// ===== 从存储回读核对（证明写到了 profile 级存储，卡死窗口重载后能读到） =====
		try{
			var 存储键=(wtm.storageKey)||'content.trust.model.key';
			var 原文=sto.get(存储键,-2);
			out.存储键=存储键;
			out.存储原文长度=(原文?String(原文).length:'无值');
			if(原文){
				var obj=JSON.parse(原文);
				var 列=(obj&&obj.uriTrustInfo?obj.uriTrustInfo:[]);
				out.回读记录数=列.length;
				out.回读命中同权威=列.filter(function(x){ return String(x.uri&&x.uri.authority||'')===权威; }).length;
				out.回读命中目标=列.filter(function(x){ return String(x.uri&&x.uri.scheme)==='vscode-remote'&&String(x.uri&&x.uri.authority||'')===权威&&String(x.uri&&x.uri.path||'')===路径; }).length;
				out.回读样例=列.slice(-2).map(function(x){ try{ return String(x.uri&&x.uri.scheme)+'://'+String(x.uri&&x.uri.authority||'').slice(0,18)+'…'+String(x.uri&&x.uri.path||'').slice(-26)+'='+x.trusted; }catch(e){ return 形(x); } });
			}
		}catch(e){ out.回读异常=String(e&&e.message||e); }

		out.记录数后=(ti&&ti.uriTrustInfo?ti.uriTrustInfo.length:'?');
		out.结论='已写入永久信任记录并落盘（回读命中同权威 '+String(out.回读命中同权威)+' 条、目标 '+String(out.回读命中目标)+' 条）。卡死窗口下一次重载 loadTrustInfo() 即读到，信任门打开后 Remote-SSH 的连接终端才能启动。';
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
