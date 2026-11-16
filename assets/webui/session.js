function conduitWebUiSession({origin, prefix, token, session, handler, target, bootstrap = false, userId, failureMessage}) {
  if (window !== window.top || location.origin !== origin) return;
  const path = location.pathname;
  const api = prefix + '/api';
  if ((path !== prefix && !path.startsWith(prefix + '/')) ||
      path === api || path.startsWith(api + '/') || /%2f|%5c|\\/i.test(path)) {
    localStorage.clear(); sessionStorage.clear();
    window.stop();
    return;
  }
  if (bootstrap) {
    localStorage.clear(); sessionStorage.clear();
    localStorage.setItem('token', token);
    localStorage.setItem('conduit.session', session);
    sessionStorage.setItem('conduit.session', session);
    const abort = new AbortController();
    const ready = fetch(prefix + '/api/v1/auths/', {
      headers: {Authorization: 'Bearer ' + token},
      credentials: 'same-origin', redirect: 'error', cache: 'no-store', signal: abort.signal,
    }).then(async response => {
      if (!response.ok || (await response.json()).id !== userId) throw Error('Sign-in failed');
      if (!abort.signal.aborted && localStorage.getItem('conduit.session') === session) location.replace(target);
    }).catch(() => {
      if (!abort.signal.aborted) document.body.textContent = failureMessage;
    });
    window.conduitCloseWebUi = async () => { abort.abort(); await ready; };
    return ready;
  }
  // Reloading must not restore a session the web application signed out of.
  if (sessionStorage.getItem('conduit.session') !== session || localStorage.getItem('token') !== token) return;
  // CSP may forbid fetching blob: URLs even though the page created the Blob.
  const blobs = new Map();
  const create = URL.createObjectURL;
  const revoke = URL.revokeObjectURL;
  URL.createObjectURL = function (blob) {
    const url = create.call(this, blob);
    blobs.set(url, blob);
    return url;
  };
  URL.revokeObjectURL = function (url) {
    blobs.delete(url);
    return revoke.call(this, url);
  };
  const save = async (url, name) => {
    const parsed = new URL(url, location.href);
    if (!['blob:', 'data:'].includes(parsed.protocol)) return false;
    const blob = blobs.get(parsed.href) || await (await fetch(parsed.href)).blob();
    if (blob.size > 32 * 1024 * 1024) throw Error('File too large');
    const data = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
    if (!window.flutter_inappwebview?.callHandler) {
      await new Promise(resolve => window.addEventListener('flutterInAppWebViewPlatformReady', resolve, {once: true}));
    }
    return window.flutter_inappwebview.callHandler(handler, {data, name});
  };
  window.conduitDownload = save;
  const click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (/^(blob:|data:)/i.test(this.href)) {
      save(this.href, this.download || '').catch(() => {});
      return;
    }
    return click.call(this);
  };
  document.addEventListener('click', event => {
    const link = event.target.closest?.('a');
    if (!link || !/^(blob:|data:)/i.test(link.href)) return;
    event.preventDefault();
    save(link.href, link.download || '').catch(() => {});
  }, true);
}
