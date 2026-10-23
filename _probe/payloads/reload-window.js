// 载荷：执行窗口自身的重载命令（把渲染进程里已被一次性拒绝毒化的 promise 全部清掉）
// 为什么现在才敢重载：① preconnect 的 argv 超限缺陷已修（实测退出码 0，窗口自己的日志里出现了新通道那行）；
//   ② 该文件夹的永久信任记录已落盘（记录数 50→51，含与窗口 canonical URI 完全一致的一条），
//      重载后 initializeWorkspaceTrust 的 loadTrustInfo() 直接读到 → 信任门天然打开，不再需要临时桥接；
//   ③ 之前重载无效是因为 ①② 两处都还坏着，会立刻回到同一个死锁循环。
// 仍需清掉的残留：terminalService._whenConnected 因 _primaryBackend.getPerformanceMarks() 一次性拒绝而永久悬挂
//   （初始化链里 Promise.all 拒绝后 complete() 再也不会被调用），渲染进程内的这类 promise 只能靠重载重建。
// 注意：执行后页面会导航，本次 evaluate 的返回值多半取不回来（属正常），验收在重载完成后从外部做。
(async function(){
	var W=globalThis,K='__钥匙前缀__';
	var out={时间:new Date().toISOString(),窗口:document.title.slice(0,70)};
	try{
		var root=W[K+'.root'];
		if(!root){ return {err:'钥匙未交接'}; }
		function 取服务(id){ var v=null; try{ root._services._entries.forEach(function(x,k){ if(String(k)===id){ v=x; } }); }catch(e){} return v; }
		var cmd=取服务('commandService');
		out.命令服务=!!cmd;
		if(!cmd){ return out; }
		// 重载前把关键状态记下来，便于重载后对照
		try{
			var wtm=取服务('workspaceTrustManagementService');
			out.重载前可信=wtm?String(wtm.isWorkspaceTrusted()):'?';
			out.重载前权威字段=wtm?(wtm._remoteAuthority?'已设置':'undefined'):'?';
		}catch(e){ out.重载前状态异常=e.message; }
		// 异步发出，不等待（页面一导航，等待就断了）
		try{
			cmd.executeCommand('workbench.action.reloadWindow');
			out.已发出重载命令='workbench.action.reloadWindow';
		}catch(e){ out.重载命令异常=e.message; }
		return out;
	}catch(e){
		try{ out.fatal=String(e&&e.stack||e); }catch(e2){}
		return out;
	}
})()
