// Snck Chat: direct messaging UI helpers. Loaded after app.js so inline actions use these functions.
(() => {
  const originalProfile = window.profile;

  window.openDMUser = async function (userId) {
    try {
      const result = await api('/api/conversations/dm', {
        method: 'POST',
        body: JSON.stringify({ userId })
      });
      const conversationId = result.conversation?.id;
      if (!conversationId) throw new Error('Could not open private chat');
      closeModal();
      await loadData();
      await openDM(conversationId);
      if (typeof toggleSide === 'function') document.querySelector('#side')?.classList.remove('open');
    } catch (e) {
      toast(e.message || 'Could not open private chat');
    }
  };

  window.searchUsers = async function (q) {
    clearTimeout(window.s);
    if (q.trim().length < 2) { closeModal(); return; }
    window.s = setTimeout(async () => {
      try {
        const d = await api('/api/users/search?q=' + encodeURIComponent(q));
        const results = d.users.map(u => `
          <div class="message">
            <div>${avatar(u)}</div>
            <div class="msgbody">
              <b>${esc(u.displayName || u.username)}</b>
              <div class="muted">@${esc(u.username)} · ${esc(u.status || 'offline')}</div>
              <div class="row" style="margin-top:8px">
                <button class="btn primary" onclick="openDMUser('${u.id}')">Message</button>
                <button class="btn" onclick="addFriend('${u.id}')">Add Friend</button>
              </div>
            </div>
          </div>`).join('');
        showModal('<h2>Find someone</h2><p class="muted">Start a private chat with anyone. Friendship is optional.</p>' + (results || '<p class="muted">No users found.</p>'));
      } catch (e) { toast(e.message); }
    }, 250);
  };

  window.profile = async function (id) {
    try {
      const d = await api('/api/users/' + id);
      const u = d.user;
      if (u.id === me.id) return originalProfile(id);
      showModal(`<div class="profile">${avatar(u)}<h2>${esc(u.displayName)}</h2><div class="muted">@${esc(u.username)}</div><span class="pill">${esc(u.status)}</span><p>${esc(u.bio || 'No bio')}</p><div class="row"><button class="btn primary" onclick="openDMUser('${u.id}')">Message</button><button class="btn" onclick="addFriend('${u.id}')">Add Friend</button><button class="btn danger" onclick="blockUser('${u.id}')">Block</button></div></div>`);
    } catch (e) { toast(e.message); }
  };
})();
