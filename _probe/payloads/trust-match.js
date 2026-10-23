// 载荷：查清「信任记录明明存在、但 doGetUriTrustInfo 判为不可信」的比对失配原因（只读）
// 背景：同 profile 的欢迎窗口里，_trustStateInfo 有 2 条本权威本路径的记录（写入前已存在=true），
//   而卡死窗口里 isWorkspaceTrusted()=false、canSetWorkspaceTrust()=false（后者又反过来压掉信任提示 → 死锁）。
//   calculateWorkspaceTrust() 的取值链是 getUrisTrust(getWorkspaceUris()) → doGetUriTrustInfo(每个 uri) →
//   先 isTrustedByRemote 再遍历存储做 isEqualOrParent(e, r.uri)，取 fsPath 最长的匹配项。
//   本载荷把两侧的字符串逐字打出来对比，不猜。
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
		var wtm=取服务('workspaceTrustManagementService');
		if(!wtm){ return {err:'拿不到信任服务',窗口:out.窗口}; }
		function 细(u){
			try{
				return {
					scheme:String(u.scheme),
					authority:String(u.authority),
					authority长度:String(u.authority).length,
					path:String(u.path),
					path长度:String(u.path).length,
					fsPath:String(u.fsPath),
					toString:String(u),
					toString长度:String(u).length
				};
			}catch(e){ return {err:String(e&&e.message||e)}; }
		}
		// ① 窗口侧：信任判定的输入到底是什么 uri
		var us=null;
		try{ us=wtm.getWorkspaceUris(); }catch(e){ out.getWorkspaceUris异常=e.message; }
		out.工作区URI数=(us?us.length:'?');
		out.工作区URI详解=(us?us.map(细):null);
		try{ out.规范文件夹详解=(wtm._canonicalWorkspace&&wtm._canonicalWorkspace.folders?wtm._canonicalWorkspace.folders.map(function(f){ return 细(f.uri); }):null); }catch(e){ out.规范文件夹异常=e.message; }
		try{ out.规范化已解析=String(wtm._canonicalUrisResolved); }catch(e){}
		try{ out.可信=String(wtm.isWorkspaceTrusted()); }catch(e){}
		try{ out.强制可信=String(wtm.isWorkspaceTrustForced()); }catch(e){}
		try{ out.可设置信任=String(wtm.canSetWorkspaceTrust()); }catch(e){}
		try{ out.远程权威环境=(function(){ var es=取服务('environmentService'); return es?String(es.remoteAuthority||'(空)'):'?'; })(); }catch(e){}

		// ② 存储侧：本权威有哪些记录（全量列出，含 path 与 trusted）
		var ti=wtm._trustStateInfo;
		out.存储记录总数=(ti&&ti.uriTrustInfo?ti.uriTrustInfo.length:'无字段');
		var 权威=null;
		try{ if(us&&us.length&&us[0].authority){ 权威=String(us[0].authority); } }catch(e){}
		out.目标权威=权威?String(权威).slice(0,24)+'…(长'+String(权威).length+')':null;
		if(ti&&ti.uriTrustInfo&&权威){
			var 同权威=ti.uriTrustInfo.filter(function(x){ try{ return String(x.uri&&x.uri.authority||'')===权威; }catch(e){ return false; } });
			out.同权威记录数=同权威.length;
			out.同权威记录=同权威.map(function(x){ try{ return {trusted:String(x.trusted),path:String(x.uri.path),toString:String(x.uri).slice(-70)}; }catch(e){ return {err:String(e.message)}; } });
			// 存储里所有 vscode-remote 记录的权威摘要（看是否存在"同主机不同后缀"的近亲记录）
			try{
				var 远端全部=ti.uriTrustInfo.filter(function(x){ return String(x.uri&&x.uri.scheme||'')==='vscode-remote'; });
				var 按权威={};
				远端全部.forEach(function(x){ var a=String(x.uri.authority); 按权威[a]=(按权威[a]||0)+1; });
				out.远端记录按权威=[];
				Object.keys(按权威).forEach(function(a){ out.远端记录按权威.push({权威头:String(a).slice(0,22)+'…',长度:String(a).length,条数:按权威[a],与目标相同:(a===权威)}); });
			}catch(e){ out.远端记录统计异常=e.message; }
		}

		// ③ 逐 uri 问平台的判表函数（同步版），看它到底匹不匹配
		if(us&&us.length){
			out.doGet判表=[];
			for(var i=0;i<us.length;i++){
				var u=us[i]; var 项={序:i};
				try{ var r=wtm.doGetUriTrustInfo(u); 项.trusted=String(r.trusted); 项.命中uri=(r&&r.uri?String(r.uri).slice(-70):'null'); }catch(e){ 项.err=String(e.message); }
				try{ 项.isTrustedVirtual=String(wtm.isTrustedVirtualResource(u)); }catch(e){}
				try{ 项.isTrustedByRemote=String(wtm.isTrustedByRemote(u)); }catch(e){}
				out.doGet判表.push(项);
			}
			// getUriTrustInfo 是异步（会走 getCanonicalUri → 扩展宿主），限时竞速
			try{
				var g=await race(wtm.getUriTrustInfo(us[0]),6000);
				out.getUriTrustInfo=(g===哨?'悬挂(6秒)':(g&&g.__failed__?'异常 '+g.__failed__:JSON.stringify({trusted:String(g.trusted),uri:String(g.uri).slice(-70)})));
			}catch(e){ out.getUriTrustInfo='ERR '+e.message; }
		}

		// ④ 手动比一遍字符串：窗口侧 canonical uri 与存储记录的差异定位（长度/大小写/尾分隔符/编码）
		try{
			if(us&&us.length&&ti&&ti.uriTrustInfo&&权威){
				var 窗串=String(us[0]);
				var 近亲=ti.uriTrustInfo.filter(function(x){ try{ return String(x.uri&&x.uri.path||'').toLowerCase()===String(us[0].path).toLowerCase(); }catch(e){ return false; } });
				out.同路径记录数=近亲.length;
				out.同路径记录=近亲.map(function(x){
					var s=String(x.uri);
					return {trusted:String(x.trusted),长度:s.length,窗口侧长度:窗串.length,完全相同:(s===窗串),仅大小写不同:(s.toLowerCase()===窗串.toLowerCase()),尾分隔符:(s.charAt(s.length-1)==='/'),toString:s.slice(-80)};
				});
			}
		}catch(e){ out.手工比对异常=e.message; }

		out.结论='可信='+out.可信+'；同权威记录='+String(out.同权威记录数)+'；doGet='+JSON.stringify(out.doGet判表);
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
