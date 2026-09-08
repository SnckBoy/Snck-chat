setInterval(()=>{try{if(typeof socket!=='undefined'&&socket?.connected)socket.emit('conversation:join','global')}catch(_){ }},1000);
