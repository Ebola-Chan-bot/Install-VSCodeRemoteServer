// 渲染器载荷：终端通道就地修复（异步；同样必须在 resume 之后执行，理由同诊断脚本）。
// 两步都是在窗口内部就地改状态，不重启 pty 宿主、不触碰其它窗口与存活终端：
//
// ① 外科式直连重连（对症病灶）：backend 到 pty 宿主的直连靠一次性 pending `_directProxyClientEventually`，
//    主进程的端口握手没回信它就永久悬挂，此后每次 `_connectToDirectProxy()` 都短路进 `await` 死等
//    —— 这正是「Remote-SSH 连接终端零输出、重载窗口也无效」的物理病灶。
//    bundle 里 `onPtyHostRestart` 的处理恰好就是「清空这两个字段 + 重新 _connectToDirectProxy」，
//    我们执行同款动作，却不必真重启 pty 宿主。
//    ⚠ 确诊只认「pending 限时是否 settle」：**不能**用 isResponsive / _directProxy 有没有值当判据——
//      病灶上这两项全都显示正常（_directProxy 握手前已赋值、isResponsive 恒 true），据此跳过等于不治。
//    ⚠ 重新建链一律 fire-and-forget，绝不 await：重连本身可能再次悬挂，那正是病因，await 会把救援流程卡死。
//
// ② 强制实例化懒描述符 localPtyService：仅当它仍是懒描述符时动手（幂等，等价于用户首次开终端时的实例化路径）；
//    backend 尚未注册时，这是注册的前置条件。
//
// 占位符（由 terminalRescue.js 载入时替换）：
//   __钥匙前缀__     globalThis 键前缀，与交接脚本一致
//   __诊断竞速Ms__   单次限时竞速的等待上限
(async function(){
	try{
		var W=globalThis,K='__钥匙前缀__';
		var refs=W[K+'.refs'],ids=W[K+'.ids'],root=W[K+'.root'];
		if(!refs||!root){ return {err:'钥匙未交接'}; }
		var out={};
		var race=function(p,ms){
			var 计时;
			var 超时=new Promise(function(_,拒){ 计时=setTimeout(function(){ 拒(new Error('timeout')); },ms); });
			return Promise.race([Promise.resolve().then(function(){return p;}),超时]).finally(function(){ clearTimeout(计时); });
		};
		// ① 外科式直连重连：清掉永久悬挂的一次性 pending，重新取端口
		try{
			var 后端=await race(Promise.resolve().then(function(){return refs.terminalInstanceService.getBackend(undefined);}),__诊断竞速Ms__).catch(function(){return null;});
			if(!后端){ out.直连重连='跳过（本地 backend 未注册）'; }
			else if(typeof 后端._connectToDirectProxy!=='function'){ out.直连重连='无法执行（bundle 漂移：无 _connectToDirectProxy）'; }
			else{
				var 悬挂=false;
				if(后端._directProxyClientEventually){ try{ await race(后端._directProxyClientEventually.p,1500); }catch(e0){ 悬挂=true; } }
				out.重接前状态={responsive:后端.isResponsive,有直连代理:!!后端._directProxy,直连pending悬挂:悬挂};
				if(悬挂){
					out.直连重连='病灶确诊：端口 pending 永久悬挂 → 已清空并重新取端口';
					后端._directProxy=undefined; 后端._directProxyClientEventually=undefined; 后端._connectToDirectProxy();
				}else if(!后端.isResponsive){
					out.直连重连='backend 自称不响应 → 已清空直连状态并重新建链';
					后端._directProxy=undefined; 后端._directProxyClientEventually=undefined; 后端._connectToDirectProxy();
				}else if(!后端._directProxy){
					out.直连重连='直连尚未建立（窗口内还没用过本地终端） → 预热建链';
					后端._connectToDirectProxy(); // fire-and-forget：可能悬挂，绝不 await
				}else{
					out.直连重连='跳过（直连在位、pending 已落定、backend responsive = 健康）';
				}
				if(out.直连重连.indexOf('跳过')!==0){
					await new Promise(function(r){ setTimeout(r,1800); }); // 给重新取端口一点时间，但不死等
					try{
						// 自证修复：重连后的新 pending 落定 = 端口真的到手；仍悬挂 = 主进程侧握手不回信，只能上重锤或逃逸新窗口
						out.重接后responsive=后端.isResponsive;
						if(后端._directProxyClientEventually){
							try{ await race(后端._directProxyClientEventually.p,1500); out.重接后端口='已到手（直连建链成功）'; }
							catch(e2){ out.重接后端口='仍悬挂（主进程未回信，需重启 pty 宿主或逃逸）'; }
						}else{ out.重接后端口='无pending'; }
					}catch(e){}
				}
			}
		}catch(e){ out.直连重连='异常：'+e.message; }
		// ② 懒 localPtyService 强制实例化
		var lp=refs.localPtyService;
		var 是懒描述符=lp&&typeof lp.ctor==='function'&&(lp.staticArguments!==undefined||lp.supportsDelayedInstantiation!==undefined);
		if(是懒描述符&&ids.localPtyService){
			try{
				var fakeTrace={branch:function(){return fakeTrace;},stop:function(){}};
				var inst=await race(Promise.resolve().then(function(){return root._getOrCreateServiceInstance(ids.localPtyService,fakeTrace);}),8000);
				out.强制实例化=inst?'成功/'+(inst.constructor?inst.constructor.name:'?'):'null';
			}catch(e){ out.强制实例化='失败：'+e.message+'（实例化仍悬挂——pty host 端口路径没恢复）'; }
			try{
				var backs=Array.from(refs.terminalInstanceService.getRegisteredBackends());
				out.修复后backend数=backs.length;
			}catch(e){}
			try{
				var lb=await race(Promise.resolve().then(function(){return refs.terminalInstanceService.getBackend(undefined);}),__诊断竞速Ms__);
				out.修复后本地backend=lb?'ok':'null';
			}catch(e){ out.修复后本地backend='仍悬挂'; }
		}else{
			out.强制实例化='跳过（localPtyService '+(lp?'已是实例':'缺席')+'）';
		}
		return out;
	}catch(e){ return {fatal:String(e&&e.stack||e)}; }
})()
