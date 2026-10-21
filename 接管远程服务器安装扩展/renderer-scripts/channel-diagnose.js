// 渲染器载荷：终端通道诊断（异步；必须在 resume 之后经 Runtime.evaluate(awaitPromise) 执行——
// 帧被暂停期间 setTimeout 不走动，页内限时竞速会全部误判为超时）。
// 纯只读取证：不调用任何有副作用的方法、不强制实例化懒服务（那是修复脚本的事）。
//
// 占位符（由 terminalRescue.js 载入时替换）：
//   __钥匙前缀__     globalThis 键前缀，与交接脚本一致
//   __诊断竞速Ms__   单次限时竞速的等待上限（getBackend / pending settle 判定）
//
// 判读要点（源码实证）：`_directProxy` 在端口握手**之前**就已被赋值为通道壳，`isResponsive` 只反映
// “pty 宿主是否被判定为无响应”，不会因端口未到而变 false —— 二者在病灶上一律显示正常。
// 唯一可靠判据 = `_directProxyClientEventually.p` 限时是否 settle：端口来自主进程握手
// `createPtyHostMessageChannel`，永不回信则该 pending 永挂，此后每次建链都短路 `await` 它。
(async function(){
	try{
		var W=globalThis,K='__钥匙前缀__';
		var refs=W[K+'.refs'];
		if(!refs){ return {err:'钥匙未交接'}; }
		var out={时间:new Date().toISOString()};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(_,拒){ 计时=setTimeout(function(){ 拒(new Error('timeout')); },ms); });
			return Promise.race([Promise.resolve().then(function(){return p;}),超时]).finally(function(){ clearTimeout(计时); });
		};
		try{
			var backs=Array.from(refs.terminalInstanceService.getRegisteredBackends());
			out.已注册backend=backs.map(function(b){
				var r={authority:b.remoteAuthority===undefined?'local':String(b.remoteAuthority)};
				try{ r.responsive=b.isResponsive; }catch(e){}
				return r;
			});
		}catch(e){ out.已注册backend='ERR '+e.message; }
		try{
			var lb=await race(Promise.resolve().then(function(){return refs.terminalInstanceService.getBackend(undefined);}),__诊断竞速Ms__);
			out.本地backend=lb?('ok/'+(lb.constructor?lb.constructor.name:'?')):'null';
			// 病灶字段取证：窗口的 LocalTerminalBackend 直连 pty 宿主靠 _directProxy（MessagePort 通道代理）+
			// _directProxyClientEventually（一次性 pending：_connectToDirectProxy 见它存在就死等）。端口未到达即永久悬挂。
			if(lb){
				try{
					out.localBackend={responsive:lb.isResponsive,有直连代理:!!lb._directProxy,有pendingEventually:!!lb._directProxyClientEventually,pty数:(lb._ptys&&lb._ptys.size)};
					if(lb._directProxyClientEventually){
						try{ await race(lb._directProxyClientEventually.p,1200); out.localBackend.直连pending='已落定（健康）'; }
						catch(e1){ out.localBackend.直连pending='悬挂——端口从未到达，即病灶'; }
					}else{ out.localBackend.直连pending='无pending（尚未尝试直连）'; }
				}catch(e){ out.localBackend='读字段失败 '+e.message; }
				W[K+'.localBackend']=lb;
			}
		}catch(e){ out.本地backend='悬挂或出错：'+e.message; }
		try{ out.connectionState=Number(refs.terminalService.connectionState); }catch(e){ out.connectionState='ERR '+e.message; }
		try{
			var lp=refs.localPtyService;
			if(!lp){ out.localPtyService='容器内缺席'; }
			else if(typeof lp.ctor==='function'&&(lp.staticArguments!==undefined||lp.supportsDelayedInstantiation!==undefined)){ out.localPtyService='懒描述符（从未实例化）'; }
			else{ out.localPtyService={ctor:lp.constructor&&lp.constructor.name}; try{ out.localPtyService.isResponsive=lp.isResponsive; }catch(e){} }
		}catch(e){ out.localPtyService='ERR '+e.message; }
		try{
			var ra=refs.remoteAgentService;
			if(ra&&typeof ra.getConnection==='function'){ var c=ra.getConnection(); out.remoteAgent连接=c?'connected':'null'; }
		}catch(e){ out.remoteAgent连接='ERR '+e.message; }
		return out;
	}catch(e){ return {fatal:String(e&&e.stack||e)}; }
})()
