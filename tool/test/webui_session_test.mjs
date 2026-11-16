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
function page({url = origin + '/document-preview/', main = true, local = storage(), tab = storage()} = {}) {
  const calls = [];
  class Reader {
    async readAsDataURL(blob) {
      this.result = 'data:application/octet-stream;base64,' + Buffer.from(await blob.arrayBuffer()).toString('base64');
      this.onload();
    }
  }
  const window = {flutter_inappwebview: {callHandler: async (handler, value) => {calls.push(value); return true;}}};
  window.top = main ? window : {};
  const sandbox = {window, location: new URL(url), localStorage: local, sessionStorage: tab, FileReader: Reader, Promise};
  vm.createContext(sandbox);vm.runInContext(source, sandbox);
  const seed = (token, session) => sandbox.conduitWebUiSession({origin, path:'/document-preview/', token, session, handler:'save'});
  return {seed, local, tab, calls, window};
}

test('a new account replaces browser state; reloading does not silently undo logout', () => {
  const local = storage();
  const first = page({local});first.seed('token-a','view-a');
  local.setItem('private-draft','account a');
  const second = page({local});second.seed('token-b','view-b');
  assert.equal(local.getItem('private-draft'),null);
  assert.equal(local.getItem('token'),'token-b');
  local.setItem('token','');second.seed('token-b','view-b');
  assert.equal(local.getItem('token'),'');
});

test('subframes, other origins and uploaded HTML receive no token or save bridge', () => {
  for(const options of [{main:false},{url:'https://other.example/document-preview/'},{url:origin+'/api/v1/files/untrusted/content/html'}]) {
    const p=page(options);p.seed('secret','view');
    assert.equal(p.local.getItem('token'),null);
    assert.equal(p.window.conduitSaveDocument,undefined);
  }
});

test('a document is handed directly to native save with its original name and bytes', async () => {
  const p=page();p.seed('token','view');
  assert.equal(await p.window.conduitSaveDocument(new Blob(['synthetic document']),'demo.xlsx'),true);
  assert.equal(p.calls.length,1);
  assert.equal(p.calls[0].name,'demo.xlsx');
  assert.equal(Buffer.from(p.calls[0].data.split(',')[1],'base64').toString(),'synthetic document');
});

test('oversized blobs never enter the bridge', async () => {
  const p=page();p.seed('token','view');
  await assert.rejects(p.window.conduitSaveDocument({size:32*1024*1024+1},'huge.xlsx'),/File too large/);
  assert.equal(p.calls.length,0);
});
