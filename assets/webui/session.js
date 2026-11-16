function conduitWebUiSession({origin, path, token, session, handler}) {
  if (window !== window.top || location.origin !== origin || location.pathname !== path) return;
  // A new native view must not inherit another account's browser drafts/settings.
  if (sessionStorage.getItem('conduit.session') !== session) {
    localStorage.clear();
    sessionStorage.clear();
    localStorage.setItem('token', token);
    localStorage.setItem('conduit.session', session);
    sessionStorage.setItem('conduit.session', session);
  }
  window.conduitSaveDocument = async (blob, name) => {
    if (blob.size > 32 * 1024 * 1024) throw Error('File too large');
    const data = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
    const save = () => window.flutter_inappwebview.callHandler(handler, {data, name});
    if (window.flutter_inappwebview?.callHandler) return save();
    return new Promise(resolve => window.addEventListener('flutterInAppWebViewPlatformReady',
      () => resolve(save()), {once: true}));
  };
}
