import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {test} from 'node:test';

const source = readFileSync(new URL('../../assets/webui/session.js', import.meta.url), 'utf8');
const origin = 'https://webui.example';
function storage() {
  const map = new Map();
  return {getItem: key => map.get(key) ?? null, setItem: (key, value) => map.set(key, String(value)), clear: () => map.clear()};
}
function page({url = origin + '/', main = true, local = storage(), tab = storage(), fetcher} = {}) {
  const calls = [], requests = [], navigations = [];
  const waiting = [];
  class Anchor {click() {this.clicked = true;}}
  class PageURL extends URL {}
  class Reader {
    async readAsDataURL(blob) {
      this.result = 'data:application/octet-stream;base64,' + Buffer.from(await blob.arrayBuffer()).toString('base64');
      this.onload();
    }
  }
  const window = {stop() {}, flutter_inappwebview: {callHandler: async (_, value) => {calls.push(value); waiting.shift()?.(value); return true;}}};
  window.top = main ? window : {};
  const document = {body: {}, addEventListener() {}};
  const location = new URL(url);location.replace = target => navigations.push(target);
  const fetch = async (url, options) => {
    requests.push({url, options});
    if (fetcher) return fetcher(url, options);
    if (url.startsWith('blob:')) return {blob: async () => new Blob(['synthetic bytes'])};
    return {ok: true, json: async () => ({id: 'a'})};
  };
  const sandbox = {window, document, location, localStorage: local, sessionStorage: tab,
    HTMLAnchorElement: Anchor, FileReader: Reader, Promise, AbortController, URL: PageURL, fetch};
  vm.createContext(sandbox);vm.runInContext(source, sandbox);
  const seed = (args = {}) => sandbox.conduitWebUiSession({origin, prefix: '', token: 'token-a', userId: 'a', session: 'view-a', handler: 'save', target: origin + '/viewer', failureMessage: 'Localized failure', ...args});
  return {seed, local, tab, calls, requests, navigations, window, document, Anchor, URL: PageURL, nextCall: () => new Promise(resolve => waiting.push(resolve))};
}

test('bootstrap validates the native account before opening the target; credentials stay out of URLs', async () => {
  const p = page();p.local.setItem('private-draft', 'previous account');
  await p.seed({bootstrap: true});
  assert.equal(p.local.getItem('private-draft'), null);
  assert.equal(p.local.getItem('token'), 'token-a');
  assert.equal(p.requests[0].url, '/api/v1/auths/');
  assert.equal(p.requests[0].options.headers.Authorization, 'Bearer token-a');
  assert.equal(p.requests[0].options.redirect, 'error');
  assert.deepEqual(p.navigations, [origin + '/viewer']);
});

test('a changed session prevents a delayed handoff from navigating', async () => {
  let finish;
  const p = page({fetcher: () => new Promise(resolve => {finish = resolve;})});
  const pending = p.seed({bootstrap: true});
  p.local.setItem('conduit.session', 'view-b');p.local.setItem('token', 'token-b');
  finish({ok: true, json: async () => ({id: 'a'})});
  await pending;
  assert.deepEqual(p.navigations, []);
  assert.equal(p.local.getItem('token'), 'token-b');
});

test('another server-side identity cannot complete the handoff', async () => {
  const p = page({fetcher: async () => ({ok: true, json: async () => ({id: 'b'})})});
  await p.seed({bootstrap: true});
  assert.deepEqual(p.navigations, []);
  assert.equal(p.document.body.textContent, 'Localized failure');
});

test('subframes, foreign origins and API documents receive no handoff or download bridge', () => {
  for (const options of [{main: false}, {url: 'https://other.example/'}, {url: origin + '/api/v1/files/demo/content/html'}]) {
    const p = page(options);p.seed({bootstrap: true});
    assert.equal(p.local.getItem('token'), null);
    assert.equal(p.window.conduitDownload, undefined);
    assert.equal(p.requests.length, 0);
  }
});

test('a normal page reuses its session; reloading never restores a signed-out token', () => {
  const p = page();p.local.setItem('token', 'token-a');p.tab.setItem('conduit.session', 'view-a');
  p.seed();assert.equal(typeof p.window.conduitDownload, 'function');
  p.local.setItem('token', '');p.window.conduitDownload = undefined;
  p.seed();assert.equal(p.local.getItem('token'), '');assert.equal(p.window.conduitDownload, undefined);
});

test('blob downloads retain original names and bytes, including detached anchors', async () => {
  const p = page();p.local.setItem('token', 'token-a');p.tab.setItem('conduit.session', 'view-a');p.seed();
  assert.equal(await p.window.conduitDownload('blob:' + origin + '/synthetic', 'Synthetic.xlsx'), true);
  assert.equal(p.calls[0].name, 'Synthetic.xlsx');
  assert.equal(Buffer.from(p.calls[0].data.split(',')[1], 'base64').toString(), 'synthetic bytes');
  const nextCall = p.nextCall();
  const link = new p.Anchor();link.href = 'blob:' + origin + '/detached';link.download = 'Detached.pdf';link.click();
  await nextCall;
  assert.equal(link.clicked, undefined);
  assert.equal(p.calls[1].name, 'Detached.pdf');
});

test('oversized blobs never enter the native bridge', async () => {
  const p = page({fetcher: async () => ({blob: async () => ({size: 32 * 1024 * 1024 + 1})})});
  p.local.setItem('token', 'token-a');p.tab.setItem('conduit.session', 'view-a');p.seed();
  await assert.rejects(p.window.conduitDownload('blob:' + origin + '/large', 'Huge.pdf'), /File too large/);
  assert.equal(p.calls.length, 0);
});

test('a generated blob downloads under CSP without fetching its URL, even after immediate revocation', async () => {
  const p = page({fetcher: async () => {throw Error('CSP forbids blob fetch');}});
  p.local.setItem('token', 'token-a');p.tab.setItem('conduit.session', 'view-a');p.seed();
  const url = p.URL.createObjectURL(new Blob(['CSP-safe synthetic bytes']));
  const link = new p.Anchor();link.href = url;link.download = 'CSP.pdf';
  const nextCall = p.nextCall();link.click();p.URL.revokeObjectURL(url);
  const saved = await nextCall;
  assert.equal(saved.name, 'CSP.pdf');
  assert.equal(Buffer.from(saved.data.split(',')[1], 'base64').toString(), 'CSP-safe synthetic bytes');
  assert.equal(p.requests.length, 0);
});
