// 渲染器载荷：钥匙交接（同步，在 Debugger.evaluateOnCallFrame 的断点帧作用域内执行）。
// 帧的 this = InstantiationService 容器。职责只有一件：把终端相关服务引用与根容器存进 globalThis 后立即返回，耗时的状态读取与修复一律放到 resume 之后的 Runtime.evaluate（帧被暂停期间 setTimeout 不走动，限时竞速会全部误判超时）。
//
// 占位符（由 terminalRescue.js 载入时替换，缺失会报错而非静默）：__钥匙前缀__  globalThis 键前缀，须与宿主侧一致（哨兵去重、后续脚本取键）
//
// 硬约束：
//  - 正文里绝不能出现反引号（宿主页内求值的表达式，反引号会与模板字符串语义混淆）
//  - 容器里取到的服务是 DI bound 代理，只暴露接口方法；下划线方法（_getOrCreateServiceInstance 等）只在根容器真身上可用，故 root 与懒描述符的标识键（Symbol/装饰器对象引用）必须一并保存
//  - 幂等：已装载则直接返回，绝不重复覆盖既有引用（重复 evaluate 是常态）
(function(recv){
	try{
		var W=globalThis;
		if(W['__钥匙前缀__.installed']){ return {already:true}; }
		if(!recv||typeof recv!=='object'||!recv._services){ return {err:'recv 不是容器',ctor:recv&&recv.constructor&&recv.constructor.name}; }
		var root=recv,g=0;
		while(root._parent&&g++<60){ root=root._parent; }
		var entries=root._services&&root._services._entries;
		if(!entries||typeof entries.forEach!=='function'){ return {err:'根容器无 _entries'}; }
		var refs={},ids={};
		entries.forEach(function(v,k){
			var kn='';try{kn=String(k);}catch(e){}
			if(kn==='terminalInstanceService'||kn==='terminalService'||kn==='remoteAgentService'||kn==='localPtyService'){
				refs[kn]=v; ids[kn]=k;
			}
		});
		if(!refs.terminalInstanceService||!refs.terminalService){ return {err:'容器链缺终端服务（bundle 结构漂移？）',已有:Object.keys(refs)}; }
		W['__钥匙前缀__.refs']=refs;
		W['__钥匙前缀__.ids']=ids;
		W['__钥匙前缀__.root']=root;
		W['__钥匙前缀__.installed']=true;
		return {ok:true,keys:Object.keys(refs),containerEntries:entries.size};
	}catch(e){ return {fatal:String(e&&e.stack||e)}; }
})(this)
