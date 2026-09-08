(() => {
  const enhanceLogin = () => {
    const modal = document.querySelector('#app > .modal');
    const card = modal?.querySelector('.card');
    const username = document.querySelector('#username');
    if (!modal || !card || !username || card.dataset.snckLanding === '1') return;

    card.dataset.snckLanding = '1';
    card.className = 'landing-card';
    card.innerHTML = `
      <nav class="landing-nav" aria-label="Primary navigation">
        <a class="landing-brand" href="#" aria-label="Snck Chat home">
          <span class="landing-logo">S</span>
          <span>Snck<span>Chat</span></span>
        </a>
        <div class="landing-nav-actions">
          <a href="#features" class="landing-nav-link">Features</a>
          <a href="#community" class="landing-nav-link">Community</a>
          <button type="button" class="landing-theme" id="landingTheme" aria-label="Toggle theme">☼</button>
          <button type="button" class="landing-cta" id="landingNavCta">Get started</button>
        </div>
      </nav>

      <main class="landing-hero" id="community">
        <div class="landing-copy">
          <div class="landing-badge"><i></i> Realtime conversations, made simple</div>
          <h1>Talk freely.<br><span>Stay connected.</span></h1>
          <p class="landing-subtitle">A fast, private and beautifully crafted chat space for real people. Join with a username and start talking in seconds.</p>

          <div class="landing-actions" id="start">
            <form class="landing-form" id="landingForm">
              <label for="username">Choose your username</label>
              <div class="landing-input-wrap">
                <span>@</span>
                <input id="username" maxlength="24" placeholder="your_username" autocomplete="off" spellcheck="false" />
                <button class="landing-primary" type="submit">Enter chat <b>→</b></button>
              </div>
              <small>No email • No password • No unnecessary signup</small>
            </form>
          </div>

          <div class="landing-trust">
            <div><strong>Realtime</strong><span>Messaging</span></div>
            <div><strong>Private</strong><span>1-to-1 DMs</span></div>
            <div><strong>Everywhere</strong><span>Mobile & desktop</span></div>
          </div>
        </div>

        <div class="landing-preview" id="features" aria-hidden="true">
          <div class="preview-glow"></div>
          <div class="preview-window">
            <div class="preview-top">
              <div class="preview-user"><span class="preview-avatar">S</span><div><b>Snck Chat</b><small><i></i> Live now</small></div></div>
              <span class="preview-dots">•••</span>
            </div>
            <div class="preview-channel"><span>✦</span><div><b>Global lounge</b><small>Everyone is welcome here</small></div></div>
            <div class="preview-messages">
              <div class="preview-message"><span class="pm-avatar a">A</span><div><b>Alex <small>12:42</small></b><p>Hey everyone! 👋</p></div></div>
              <div class="preview-message"><span class="pm-avatar b">M</span><div><b>Mia <small>12:43</small></b><p>This place feels so smooth ✨</p><em>❤️ 12</em></div></div>
              <div class="preview-message"><span class="pm-avatar c">J</span><div><b>Jordan <small>12:44</small></b><p>Let's start chatting 🚀</p></div></div>
            </div>
            <div class="preview-composer"><span>Write a message...</span><button>↑</button></div>
          </div>
        </div>
      </main>

      <section class="landing-features">
        <span>⚡ Instant realtime chat</span><span>🔒 Private conversations</span><span>👥 Username friends</span><span>📱 Built for every screen</span>
      </section>
    `;

    const form = document.querySelector('#landingForm');
    const cta = document.querySelector('#landingNavCta');
    const theme = document.querySelector('#landingTheme');
    const focusName = () => document.querySelector('#username')?.focus();
    form?.addEventListener('submit', (event) => { event.preventDefault(); window.login?.(); });
    cta?.addEventListener('click', focusName);
    theme?.addEventListener('click', () => {
      const next = document.body.classList.contains('light') ? 'dark' : 'light';
      document.body.className = next;
      localStorage.setItem('snck_theme', next);
      theme.textContent = next === 'light' ? '☾' : '☼';
    });
    modal.classList.add('landing-modal');
  };

  const observer = new MutationObserver(enhanceLogin);
  observer.observe(document.body, { childList: true, subtree: true });
  enhanceLogin();
})();
