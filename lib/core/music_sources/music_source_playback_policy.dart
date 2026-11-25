/// Host policy for the reviewed Qingliu script's same-song Kuwo fallback.
/// This is not a sandbox for arbitrary scripts or third-party servers.
const musicSourcePlaybackPolicyScript = r'''
(function () {
  var config = {};
  Object.defineProperty(config, 'allowSameSongFallback', {
    value: false,
    enumerable: true
  });
  Object.defineProperty(globalThis, '__QINGLIU_CONFIG__', {
    value: config
  });
})();
''';
