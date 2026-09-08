/* Snck Chat UX enhancements: accepted friends can immediately open a private DM. */
(function(){
  const escHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  window.startDM=async function(userId){
    try{
      const d=await window.api('/api/conversations/dm',{method:'POST',body:JSON.stringify({userId})});
      if(d?.conversation?.id && typeof window.openDM==='function') await window.openDM(d.conversation.id);
      if(typeof window.closeModal==='function') window.closeModal();
      if(typeof window.toast==='function') window.toast('Private chat opened ✓');
    }catch(e){if(typeof window.toast==='function')window.toast(e.message)}
  };
  window.openFriendProfile=async function(id){
    try{
      const [userResult,friendResult]=await Promise.all([
        window.api('/api/users/'+encodeURIComponent(id)),
        window.api('/api/friends')
      ]);
      const u=userResult.user, isMe=u.id===window.me?.id, friends=friendResult.friends||[], friend=friends.some(x=>x.id===u.id);
      const actions=isMe?'':(friend
        ? `<button class="btn primary fullBtn" onclick="startDM('${u.id}')">Message privately</button><button class="btn" style="width:100%;margin-top:8px" onclick="removeFriend('${u.id}')">Remove friend</button>`
        : `<button class="btn primary fullBtn" onclick="addFriend('${u.id}')">Send friend request</button>`);
      window.showModal(`<div class="profile"><div class="profileHero">${window.avatar(u)}<span class="profileOnline"></span></div><h2>${escHtml(u.displayName||u.username)}</h2><div class="muted">@${escHtml(u.username)}</div><span class="pill"><i></i>${escHtml(u.status||'offline')}</span><p>${escHtml(u.bio||'No bio')}</p>${actions?`<div class="profileActions">${actions}</div>`:''}</div>`);
    }catch(e){if(typeof window.toast==='function')window.toast(e.message)}
  };
  window.profile=window.openFriendProfile;
})();
