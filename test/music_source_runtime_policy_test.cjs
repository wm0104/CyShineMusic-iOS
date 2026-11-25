'use strict';
// Run from the repository root: node --test test/music_source_runtime_policy_test.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const read = path => fs.readFileSync(path, 'utf8');
const policyPath = 'lib/core/music_sources/music_source_playback_policy.dart';
const policy = () => read(policyPath).match(/r'''([\s\S]*?)'''/)[1];
const iosPreload = 'packages/music_source_runtime/ios/Resources/music_source_preload.js';
const androidPreload = 'android/app/src/main/assets/music_source_preload.js';
const swiftPath = 'packages/music_source_runtime/ios/Classes/MusicSourceRuntimePlugin.swift';
const javaPath = 'packages/music_source_runtime/android/src/main/java/com/cyshine/music/source/MusicSourceRuntimeBridge.java';

function runtime(preload, script, applyPolicy = true) {
  const events = [];
  const context = vm.createContext({
    __music_source_native_call__: (action, data) => events.push({ action, ...JSON.parse(data) }),
    __music_source_set_timeout__: () => {},
    __music_source_clear_timeout__: () => {},
  });
  vm.runInContext(read(preload), context);
  context.music_source_setup(JSON.stringify({ rawScript: script, id: 'offline-fixture' }));
  if (applyPolicy) vm.runInContext(policy(), context);
  vm.runInContext(script, context);
  return { context, events, send: (action, data) => context.__music_source_handle__(action, JSON.stringify(data)) };
}
const flush = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };

test('policy is visible before script, locks only fallback, and preserves raw script', () => {
  const script = `/* @name untouched */\n'use strict';
    globalThis.seen = __QINGLIU_CONFIG__.allowSameSongFallback;
    globalThis.original = lx.currentScriptInfo.rawScript;`;
  for (const preload of [iosPreload, androidPreload]) {
    const { context } = runtime(preload, script);
    assert.equal(context.seen, false);
    assert.equal(context.original, script);
    assert.equal(vm.runInContext(`Reflect.set(__QINGLIU_CONFIG__, 'allowSameSongFallback', true)`, context), false);
    assert.equal(vm.runInContext(`Reflect.deleteProperty(globalThis, '__QINGLIU_CONFIG__')`, context), false);
    assert.equal(vm.runInContext(`Reflect.set(globalThis, '__QINGLIU_CONFIG__', {allowSameSongFallback:true})`, context), false);
    vm.runInContext(`__QINGLIU_CONFIG__.requestTimeoutMs = 1234`, context);
    assert.equal(context.__QINGLIU_CONFIG__.requestTimeoutMs, 1234);
  }
});

test('both loaders evaluate the same Dart policy before the untouched script', () => {
  const dart = read('lib/core/music_sources/music_source_runtime.dart');
  assert.match(dart, /'playbackPolicyScript': musicSourcePlaybackPolicyScript/);
  assert.match(dart, /'script': script/);
  assert.match(dart, /'source': music.source.code/);
  assert.match(dart, /'musicInfo': toOldMusicInfoJson\(music, quality: quality\)/);
  const swift = read(swiftPath), java = read(javaPath);
  assert.match(swift, /args\["playbackPolicyScript"\]/);
  assert.match(swift, /info\["rawScript"\] = script/);
  assert.ok(swift.indexOf('evaluateScript(playbackPolicyScript, in: context)') >= 0);
  assert.ok(swift.indexOf('evaluateScript(playbackPolicyScript, in: context)') < swift.indexOf('evaluateScript(script, in: context)'));
  assert.match(java, /arguments.get\("playbackPolicyScript"\)/);
  assert.match(java, /metadata.put\("rawScript", script\)/);
  assert.ok(java.indexOf('jsContext.evaluate(playbackPolicyScript)') >= 0);
  assert.ok(java.indexOf('jsContext.evaluate(playbackPolicyScript)') < java.indexOf('jsContext.evaluate(script)'));
  assert.equal(read(iosPreload), read(androidPreload));
});

test('wy/tx/kw requests retain IDs, source and quality while queued; abort stays isolated', async () => {
  for (const preload of [iosPreload, androidPreload]) {
    const script = `globalThis.received = [];
      lx.on('request', event => {
        received.push(event);
        return new Promise((resolve, reject) => {
          const abort = lx.request('https://offline.invalid/' + event.info.musicInfo.songmid, {}, (error) => {
            if (error) reject(error); else resolve('https://offline.invalid/result');
          });
          if (event.info.musicInfo.songmid === 'abort-me') {
            abort(); reject(new Error('fixture abort'));
          }
        });
      });`;
    const r = runtime(preload, script);
    const inputs = [
      { requestId: '1', source: 'wy', quality: 'flac', musicInfo: { songmid: 'wy-original', name: 'same name', singer: 'same artist' } },
      { requestId: '2', source: 'tx', quality: '320k', musicInfo: { songmid: 'abort-me' } },
      { requestId: '3', source: 'kw', quality: '128k', musicInfo: { songmid: 'kw-original' } },
    ];
    inputs.forEach(input => r.send('resolve', input));
    assert.equal(r.context.received.length, 1);
    r.send('httpResponse', { requestId: '1', response: {} });
    await flush();
    assert.equal(r.context.received.length, 3);
    r.send('httpResponse', { requestId: '2', response: {} }); // canceled response ignored
    r.send('httpResponse', { requestId: '3', response: {} });
    await flush();
    const actual = JSON.parse(JSON.stringify(r.context.received));
    assert.deepEqual(actual, inputs.map(p => ({ source: p.source, action: 'musicUrl', info: { type: p.quality, musicInfo: p.musicInfo } })));
    assert.deepEqual(r.events.filter(e => e.action === 'resolveResult').map(e => [e.requestId, e.status]), [['1', true], ['2', false], ['3', true]]);
    assert.deepEqual(r.events.filter(e => e.action === 'httpCancel').map(e => e.requestId), ['2']);
  }
});

const reviewedScript = process.env.QINGLIANG_REVIEWED_SCRIPT;
test('reviewed real script schedules same-platform jobs but never matchKuwo (offline)', { skip: !reviewedScript }, async () => {
  const original = read(reviewedScript);
  assert.equal(crypto.createHash('sha256').update(original).digest('hex'), 'f5d589c4ebe583800b25fe12e35dfd4f807f1758bfbea83054df4b9a4f95aa29');
  // In-memory probes only; never redistribute or modify the source file.
  const instrumented = original.replace('function matchKuwo(ctx, info) {', 'function matchKuwo(ctx, info) { globalThis.matchCalls++;')
    .replace('function jobs(ctx, source, info, quality) {', 'function jobs(ctx, source, info, quality) { globalThis.jobInputs.push({source, info, quality});');
  assert.notEqual(instrumented, original);
  for (const preload of [iosPreload, androidPreload]) {
    for (const applyPolicy of [false, true]) {
      const r = runtime(preload, 'globalThis.matchCalls = 0; globalThis.jobInputs = [];\n' + instrumented, applyPolicy);
      for (const [source, id] of [['wy', '123456'], ['tx', 'tx-original']]) {
        r.send('resolve', { requestId: source, source, quality: '128k', musicInfo: { songmid: id, name: 'fixture title', singer: 'fixture artist' } });
        for (let i = 0; i < 40; i++) {
          await flush();
          // Native HTTP is captured, never sent. Fail every captured operation.
          for (const event of r.events.filter(e => e.action === 'httpRequest' && !e.answered)) {
            event.answered = true;
            r.send('httpResponse', { requestId: event.requestId, error: 'offline fixture failure' });
          }
        }
      }
      assert.equal(r.context.jobInputs.length, 2);
      assert.deepEqual(JSON.parse(JSON.stringify(r.context.jobInputs)).map(x => [x.source, x.info.songmid, x.quality]), [['wy', '123456', '128k'], ['tx', 'tx-original', '128k']]);
      if (applyPolicy) assert.equal(r.context.matchCalls, 0);
      else assert.ok(r.context.matchCalls > 0, 'positive control must exercise the cross-platform path');
      assert.ok(r.events.some(e => e.action === 'httpRequest'), 'same-platform routes still run');
      assert.equal(r.events.filter(e => e.action === 'resolveResult').length, 2);
    }
  }
});

test('unmodified downloaded script runs offline and retains exact rawScript', { skip: !reviewedScript }, async () => {
  const original = read(reviewedScript);
  for (const preload of [iosPreload, androidPreload]) {
    const r = runtime(preload, original);
    assert.equal(r.context.lx.currentScriptInfo.rawScript, original);
    r.send('resolve', { requestId: 'unmodified-wy', source: 'wy', quality: '128k', musicInfo: { songmid: '123456', name: 'fixture title', singer: 'fixture artist' } });
    for (let i = 0; i < 40; i++) {
      await flush();
      for (const event of r.events.filter(e => e.action === 'httpRequest' && !e.answered)) {
        event.answered = true;
        r.send('httpResponse', { requestId: event.requestId, error: 'offline fixture failure' });
      }
    }
    const requests = r.events.filter(e => e.action === 'httpRequest');
    assert.ok(requests.length > 0);
    assert.ok(requests.every(e => !e.url.includes('kuwo.cn')));
    assert.deepEqual(r.events.filter(e => e.action === 'resolveResult').map(e => [e.requestId, e.status]), [['unmodified-wy', false]]);
  }
});
