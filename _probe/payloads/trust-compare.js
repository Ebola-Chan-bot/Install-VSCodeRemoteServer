// 载荷：逐条比对"窗口侧 canonical URI"与"存储里的同权威记录"，定位 doGetUriTrustInfo 判 false 的确切原因（只读）
// 已知：卡死窗口 isWorkspaceTrusted=false，但存储里存在一条 String(uri) 与窗口 canonical URI **完全相同**（长度都是 191）的记录，
//   doGetUriTrustInfo 却返回 trusted=false → 说明 extUri 的比较没通过（大小写敏感性 / revive 后的对象身份 / 组件差异）。
// 只有查清这一点，"写入永久信任记录"这条修复才可靠（否则重载后 revive 的记录仍旧比对不上，窗口会永远在重载循环里）。
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString(),窗口:document.title.slice(0,70)};
	try{
		var root=W[K+'.root'];
		if(!root){ return {err:'钥匙未交接'}; }
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var wtm=取服务('workspaceTrustManagementService');
		var ui=取服务('uriIdentityService');
		out.服务={信任:!!wtm,uriIdentity:!!ui};
		if(!wtm){ return out; }
		var us=wtm.getWorkspaceUris();
		var q=us[0];
		out.查询侧={构造名:(q&&q.constructor&&q.constructor.name)||'?',scheme:String(q.scheme),authority长:String(q.authority).length,path:String(q.path),fsPath:String(q.fsPath),toString长:String(q).length};
		var ext=(ui&&ui.extUri)||null;
		out.有extUri=!!ext;
		var ti=wtm._trustStateInfo;
		var 权威=String(q.authority);
		out.比对=[];
		var n=0;
		ti.uriTrustInfo.forEach(function(x){
			var r=x.uri;
			if(String(r&&r.authority||'')!==权威){ return; }
			n++;
			var 项={序:n,trusted:String(x.trusted)};
			try{ 项.构造名=(r.constructor&&r.constructor.name)||'?'; }catch(e){ 项.构造名='?'; }
			try{ 项.同构造=(r.constructor===q.constructor); }catch(e){}
			try{ 项.scheme相同=(String(r.scheme)===String(q.scheme)); }catch(e){}
			try{ 项.authority精确相同=(String(r.authority)===权威); }catch(e){}
			try{ 项.path=r?String(r.path):'null'; 项.path精确相同=(String(r.path)===String(q.path)); 项.path忽略大小写相同=(String(r.path).toLowerCase()===String(q.path).toLowerCase()); }catch(e){}
			try{ 项.toString相同=(String(r)===String(q)); }catch(e){}
			try{ 项.fsPath=String(r.fsPath); }catch(e){}
			if(ext){
				try{ 项.extUri_isEqual=String(ext.isEqual(q,r)); }catch(e){ 项.extUri_isEqual='ERR '+e.message; }
				try{ 项.extUri_isEqual忽略大小写=String(ext.isEqual(q,r,true)); }catch(e){ 项.isEqual忽略大小写ERR=e.message; }
				try{ 项.extUri_isEqualOrParent=String(ext.isEqualOrParent(q,r)); }catch(e){ 项.extUri_isEqualOrParent='ERR '+e.message; }
				try{ 项.extUri_isEqualOrParent忽略大小写=String(ext.isEqualOrParent(q,r,true)); }catch(e){}
			}
			try{ 项.doGet单条=(function(){ var t=!1; /* 复刻 doGetUriTrustInfo 的遍历判据，单条 */ t=ext?ext.isEqualOrParent(q,r):false; return String(t); })(); }catch(e){}
			out.比对.push(项);
		});
		out.同权威记录数=n;
		// 平台判表结果对照
		try{ var g=wtm.doGetUriTrustInfo(q); out.doGet平台={trusted:String(g.trusted),uri:String(g.uri),与查询侧同对象:(g.uri===q)}; }catch(e){ out.doGet平台ERR=e.message; }
		try{ out.虚拟资源=String(wtm.isTrustedVirtualResource(q)); }catch(e){}
		try{ out.按远端可信=String(wtm.isTrustedByRemote(q)); }catch(e){}
		try{ out.可信=String(wtm.isWorkspaceTrusted()); }catch(e){}
		// 环境里 extUri 的比较器是否忽略大小写（决定大小写差异是否致命）
		try{ if(ext&&ext.ignorePathCasing){ out.extUri忽略路径大小写=String(ext.ignorePathCasing(q)); } }catch(e){}
		try{ if(ext&&ext.ignoreCase){ out.extUri忽略大小写策略=String(ext.ignoreCase); } }catch(e){}
		// 反证：把记录里的对象**当作**查询侧再问一次，看是否 trusted（若为 true 说明失配源自"查询侧 uri 对象与存储对象不等价"）
		try{
			out.反证=[];
			ti.uriTrustInfo.forEach(function(x){
				if(String(x.uri&&x.uri.authority||'')!==权威){ return; }
				try{ var rr=wtm.doGetUriTrustInfo(x.uri); out.反证.push({存储uri:String(x.uri).slice(-46),trusted:String(rr.trusted)}); }catch(e){ out.反证.push({err:e.message}); }
			});
		}catch(e){}
		out.结论='可信='+out.可信+'；同权威记录='+n+'；doGet='+JSON.stringify(out.doGet平台)+'；extUri_isEqual='+(out.比对.length?out.比对.map(function(b){ return String(b.extUri_isEqual); }).join(','):'-');
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
