// 载荷：窗口卫生清理——还原仪表化留下的 monkey patch、销毁历次探针终端。
// 任何载荷异常退出后都应补跑一次本载荷，确保用户窗口里不留探针痕迹（这是本轮实测的收尾义务）。
(async function(){
	try{
		var W=globalThis,K='__钥匙前缀__';
		var refs=W[K+'.refs'];
		var out={时间:new Date().toISOString()};
		// ① 还原包裹（按登记表逐个写回原函数；未登记的残留扫描原型链）
		var 还原=0;
		try{
			var 表=W[K+'.wrappers'];
			if(表&&表.length){
				for(var i=0;i<表.length;i++){
					var 项=表[i];
					try{
						if(项.宿主[项.名字]&&项.宿主[项.名字].__vsiWrapped){
							if(项.可写){ 项.宿主[项.名字]=项.原函数; }
							else{ Object.defineProperty(项.宿主,项.名字,{value:项.原函数,writable:false,configurable:true,enumerable:false}); }
							还原++;
						}
					}catch(e){}
				}
			}
			W[K+'.wrappers']=null;
		}catch(e){ out.还原错误=String(e&&e.message||e); }
		out.已还原包裹=还原;
		// ② 销毁登记的探针终端
		var 销毁=0; var 销毁明细=[];
		try{
			var 表2=(W[K+'.probeList']||[]);
			for(var j=0;j<表2.length;j++){
				var it=表2[j];
				try{
					if(it&&typeof it.dispose==='function'){ it.dispose(); 销毁++; 销毁明细.push('#'+j+' 已销毁'); }
				}catch(e){ 销毁明细.push('#'+j+' 异常 '+String(e.message||e)); }
			}
			W[K+'.probeList']=[];
		}catch(e){ out.销毁错误=String(e&&e.message||e); }
		out.已销毁探针=销毁;
		out.销毁明细=销毁明细;
		// ③ 现状核对：实例数、本地 backend 的 _ptys、是否还有名字含 VSI 的探针残留
		try{
			if(refs){
				var 全部=(refs.terminalService.instances||[]).slice();
				out.实例数=全部.length;
				var 残留=[];
				for(var k=0;k<全部.length;k++){
					var v=全部[k]; var 标='';
					try{ 标=String(v.title||'')+'|'+String(v.name||''); }catch(e){}
					var pm=null; try{ pm=v._processManager; }catch(e){}
					if(!pm){ try{ Object.getOwnPropertyNames(v).forEach(function(nm){ var d=Object.getOwnPropertyDescriptor(v,nm); if(d&&!d.get&&d.value&&typeof d.value==='object'&&typeof d.value._instanceId==='number'){ pm=d.value; } }); }catch(e){} }
					残留.push({序:k,id:(pm?pm._instanceId:'?'),title:标.slice(0,40),pid:(typeof v.processId)});
				}
				out.实例清单=残留;
			}
		}catch(e){ out.核对错误=String(e&&e.message||e); }
		try{ var lb=W[K+'.localBackend']; out.本地backend_ptys=(lb&&lb._ptys)?lb._ptys.size:'?'; }catch(e){}
		// ④ 清掉本轮注入留下的调试痕迹键（保留 refs/root：钥匙载荷幂等，留着后续载荷可直接用）
		try{ W[K+'.cleanupNeeded']=false; }catch(e){}
		return out;
	}catch(e){ return {fatal:String(e&&e.stack||e)}; }
})()
