import 'package:cy_shine_music/core/services/app_update_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool newer(
    String remote, {
    int? build,
    String local = '2.0.9',
    String localBuild = '8',
  }) => isNewerOfficialVersion(
    remoteVersion: remote,
    remoteBuild: build,
    installedVersion: local,
    installedBuild: localBuild,
  );

  group('OfficialAppVersion', () {
    test('accepts supported prefixes and preserves full normalized version', () {
      for (final prefix in ['', 'v', 'V', 'ios-v']) {
        final value = OfficialAppVersion.tryParse('${prefix}2.0.9+0012')!;
        expect(value.normalized, '2.0.9+0012');
        expect(value.core, '2.0.9');
        expect(value.components, [2, 0, 9, 0]);
        expect(value.isPrerelease, isFalse);
        expect(value.build, 12);
      }
      final value = OfficialAppVersion.tryParse('ios-v2.0.9.1+release.9')!;
      expect(value.core, '2.0.9.1');
      expect(value.components, [2, 0, 9, 1]);
      expect(value.build, isNull);
    });

    test('parses prereleases without admitting them as official releases', () {
      final value = OfficialAppVersion.tryParse('v2.0.9-rc.1+9')!;
      expect(value.normalized, '2.0.9-rc.1+9');
      expect(value.isPrerelease, isTrue);
      expect(value.build, 9);
    });

    test('rejects malformed formats, leading zeros and component overflow', () {
      for (final value in [
        '', '2', '2.0', '2.0.9.0.1', '02.0.9', '2.00.9',
        '2.0.-9', '2..9', '2.0.9.', ' 2.0.9', '2.0.9\n',
        'vv2.0.9', 'ios-V2.0.9', 'ios-vv2.0.9', '2.0.9+',
        '2.0.9++1', '2.0.9+a..b', '2.0.9+bad_value', '2.0.9+-1',
        '2.0.9-', '2.0.9-rc..1', '2.0.9-01',
        '9223372036854775808.0.0',
      ]) {
        expect(OfficialAppVersion.tryParse(value), isNull, reason: value);
      }
      expect(
        OfficialAppVersion.tryParse('9223372036854775807.0.0')?.core,
        '9223372036854775807.0.0',
      );
      // Oversized metadata remains a valid identifier, but is not an Int build.
      expect(
        OfficialAppVersion.tryParse('2.0.9+9223372036854775808')?.build,
        isNull,
      );
    });
  });

  group('isNewerOfficialVersion', () {
    test('compares three and four numeric components, not strings', () {
      expect(newer('ios-v2.0.10'), isTrue);
      expect(newer('2.0.8'), isFalse);
      expect(newer('2.0.9.1'), isTrue);
      expect(newer('2.0.9', local: '2.0.9.1'), isFalse);
      expect(newer('10.0.0', local: '9.99.99.99'), isTrue);
      expect(newer('2.0.9.10', local: '2.0.9.9'), isTrue);
      expect(newer('2.0.9.0'), isFalse);
      expect(newer('2.0.9', local: '2.0.9.0'), isFalse);
    });

    test('different cores ignore build values and missing bundle build', () {
      expect(newer('2.0.10+1', local: '2.0.9+999'), isTrue);
      expect(newer('2.0.8+999', build: 999), isFalse);
      expect(newer('2.0.10', localBuild: 'unknown'), isTrue);
    });

    test('same core uses numeric metadata and legacy bundle build', () {
      expect(newer('2.0.9+9'), isTrue);
      expect(newer('2.0.9+10', localBuild: '9'), isTrue);
      expect(newer('2.0.9+8'), isFalse);
      expect(newer('2.0.9+7'), isFalse);
      expect(newer('2.0.9.0+9'), isTrue);
      expect(newer('2.0.9+0009'), isTrue);
    });

    test('explicit manifest build supports an unchanged release tag', () {
      expect(newer('ios-v2.0.9', build: 9), isTrue);
      expect(newer('ios-v2.0.9', build: 8), isFalse);
      expect(newer('ios-v2.0.9', build: 7), isFalse);
      expect(newer('2.0.9+release.9', build: 9), isTrue);
      expect(newer('2.0.9', build: 0, localBuild: '0'), isFalse);
      expect(newer('2.0.9', build: 1, localBuild: '0'), isTrue);
    });

    test('numeric metadata overrides both separate build fields', () {
      expect(newer('2.0.9+8', build: 999), isFalse);
      expect(newer('2.0.9+9', build: 1), isTrue);
      expect(newer('2.0.9+10', local: '2.0.9+9', localBuild: '999'), isTrue);
      expect(newer('2.0.9+8', local: '2.0.9+9', localBuild: '1'), isFalse);
      expect(newer('2.0.9', build: 9, local: '2.0.9+8', localBuild: 'bad'), isTrue);
      expect(newer('2.0.9+9', local: '2.0.9+release', localBuild: '8'), isTrue);
    });

    test('unknown or invalid build information cannot invent an update', () {
      expect(newer('2.0.9'), isFalse);
      expect(newer('2.0.9+release'), isFalse);
      for (final localBuild in ['', 'bad', '8.1', '0x8', ' 8', '-1']) {
        expect(newer('2.0.9+9', localBuild: localBuild), isFalse);
      }
      expect(newer('2.0.9+9223372036854775808'), isFalse);
      expect(newer('2.0.9+9', localBuild: '9223372036854775808'), isFalse);
    });

    test('invalid versions and prereleases throw instead of claiming newest', () {
      for (final value in ['bad', '2.0', '2.0.9-rc.1', '2.0.9+-1']) {
        expect(() => newer(value), throwsFormatException);
        expect(() => newer('2.0.10', local: value), throwsFormatException);
      }
      expect(() => newer('2.0.10', build: -1), throwsFormatException);
      expect(() => newer('2.0.9+10', build: -1), throwsFormatException);
    });
  });
}
