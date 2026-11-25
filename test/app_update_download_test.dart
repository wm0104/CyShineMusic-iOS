import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder, getCrc32;
import 'package:crypto/crypto.dart';
import 'package:cy_shine_music/core/services/app_update_service.dart';
import 'package:cy_shine_music/features/update/ipa_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async { directory = await Directory.systemTemp.createTemp('update-test-'); });
  tearDown(() async { await directory.delete(recursive: true); });

  test('valid IPA is accepted without claiming hash authentication', () async {
    final file = File('${directory.path}/app.ipa');
    await file.writeAsBytes(_ipa());
    expect(await validateIpaFile(file.path), isFalse);
  });
  test('invalid ZIP, missing Payload and CRC corruption are rejected', () async {
    final archive = Archive()..addFile(ArchiveFile('not-an-app.txt', 3, [1, 2, 3]));
    final corrupt = _ipa();
    // Corrupt central-directory CRC, not a private implementation detail.
    for (var i = 0; i < corrupt.length - 20; i++) {
      if (corrupt[i] == 0x50 && corrupt[i + 1] == 0x4b &&
          corrupt[i + 2] == 1 && corrupt[i + 3] == 2) {
        corrupt[i + 16] ^= 0xff;
        break;
      }
    }
    for (final bytes in [[1, 2, 3], ZipEncoder().encode(archive), corrupt]) {
      final file = File('${directory.path}/bad.ipa');
      await file.writeAsBytes(bytes);
      await expectLater(validateIpaFile(file.path), throwsA(isA<FormatException>()));
    }
  });
  test('stored and deflated ZIP fixtures retain CRC and SHA256 verification', () async {
    for (final method in [0, 8]) {
      for (final flags in [0, 8]) {
        final bytes = _zipFixture(method: method, flags: flags);
        final file = File('${directory.path}/fixture.ipa');
        await file.writeAsBytes(bytes);
        expect(await validateIpaFile(file.path), isFalse);
        expect(await validateIpaFile(file.path,
          expectedSha256: sha256.convert(bytes).toString()), isTrue);
      }
    }
  });
  test('duplicate and case-colliding central-directory names are rejected', () async {
    for (final names in [
      [_infoPath, _infoPath],
      [_infoPath, _infoPath.toLowerCase()],
    ]) {
      final file = File('${directory.path}/duplicate.ipa');
      await file.writeAsBytes(_zipFixture(names: names));
      await expectLater(validateIpaFile(file.path), throwsFormatException);
    }
  });
  test('symlink is rejected before trying to decode its invalid deflate data', () async {
    final file = File('${directory.path}/symlink.ipa');
    await file.writeAsBytes(_zipFixture(mode: 0xa1ff, method: 8,
      compressedData: [255, 255, 255]));
    await expectLater(validateIpaFile(file.path), throwsA(isA<FormatException>()
      .having((error) => error.message, 'preflight', contains('headers'))));
  });
  test('oversized central or local declaration is rejected before decoding', () async {
    for (final localOnly in [false, true]) {
      final file = File('${directory.path}/oversized.ipa');
      await file.writeAsBytes(_zipFixture(
        declaredSize: localOnly ? null : 512 * 1024 * 1024 + 1,
        localSize: 512 * 1024 * 1024 + 1));
      await expectLater(validateIpaFile(file.path), throwsFormatException);
    }
  });
  test('total declared expansion is limited before any entry is decoded', () async {
    final file = File('${directory.path}/total.ipa');
    await file.writeAsBytes(_zipFixture(names: [_infoPath,
      'Payload/CyShine.app/a', 'Payload/CyShine.app/b'],
      declaredSize: 512 * 1024 * 1024));
    await expectLater(validateIpaFile(file.path), throwsA(isA<FormatException>()
      .having((error) => error.message, 'preflight', contains('headers'))));
  });
  test('actual deflate output cannot exceed a forged small declaration', () async {
    final file = File('${directory.path}/expansion.ipa');
    await file.writeAsBytes(_zipFixture(method: 8,
      data: List<int>.filled(128 * 1024, 65), declaredSize: 1));
    await expectLater(validateIpaFile(file.path), throwsA(isA<FormatException>()
      .having((error) => error.message, 'bounded output', contains('expanded size'))));
  });
  test('unsafe paths, encrypted entries and unsupported methods are rejected', () async {
    final fixtures = [
      for (final name in ['/Payload/app.app/Info.plist', '../$_infoPath',
        'Payload/../app.app/Info.plist', 'Payload\\app.app/Info.plist'])
        _zipFixture(names: [name]),
      _zipFixture(flags: 1),
      _zipFixture(method: 99),
    ];
    for (final bytes in fixtures) {
      final file = File('${directory.path}/unsafe.ipa');
      await file.writeAsBytes(bytes);
      await expectLater(validateIpaFile(file.path), throwsFormatException);
    }
  });
  test('entry count and central-directory bounds are checked before parsing', () async {
    for (final field in [10, 12]) {
      final bytes = Uint8List.fromList(_zipFixture());
      final eocd = bytes.length - 22;
      final view = ByteData.sublistView(bytes);
      if (field == 10) {
        view.setUint16(eocd + 8, 20001, Endian.little);
        view.setUint16(eocd + 10, 20001, Endian.little);
      } else {
        view.setUint32(eocd + 12, 9 * 1024 * 1024, Endian.little);
      }
      final file = File('${directory.path}/directory.ipa');
      await file.writeAsBytes(bytes);
      await expectLater(validateIpaFile(file.path), throwsFormatException);
    }
  });
  test('damaged content is rejected even when the two header CRCs agree', () async {
    final file = File('${directory.path}/crc.ipa');
    await file.writeAsBytes(_zipFixture(crc: 0));
    await expectLater(validateIpaFile(file.path), throwsFormatException);
  });
  test('staging cleanup failure does not lose the validated file or lock retry', () async {
    final dio = Dio()..httpClientAdapter = _BytesAdapter(_ipa());
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    download.file = _UndeletableFile();
    await download.download(_release());
    expect(download.file, isNot(isA<_UndeletableFile>()));
    expect(download.releaseTag, _release().tagName);
    expect(download.downloading, isFalse);
    expect(await download.file!.exists(), isTrue);
    await download.download(_release());
    expect(download.downloading, isFalse);
    expect(download.message, contains('未提供 SHA256'));
    download.dispose();
    dio.close();
  });
  test('wrong official SHA256 is rejected', () async {
    final file = File('${directory.path}/app.ipa');
    await file.writeAsBytes(_ipa());
    await expectLater(validateIpaFile(file.path, expectedSha256: '0' * 64),
        throwsA(isA<FormatException>()));
  });
  test('manifest SHA256 verifies the IPA without a second checksum request', () async {
    final bytes = _ipa();
    final digest = sha256.convert(bytes).toString();
    final adapter = _BytesAdapter(bytes);
    final dio = Dio()..httpClientAdapter = adapter;
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    await download.download(_release(digest: digest, build: 9));
    expect(download.file, isNotNull);
    expect(download.hashVerified, isTrue);
    expect(download.releaseBuildNumber, 9);
    expect(download.releaseSha256, digest);
    expect(download.message, contains('SHA256 一致'));
    download.dispose();
    dio.close();
  });
  test('mismatched manifest SHA256 never publishes a file', () async {
    final dio = Dio()..httpClientAdapter = _BytesAdapter(_ipa());
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    await download.download(_release(digest: '0' * 64, build: 9));
    expect(download.file, isNull);
    expect(download.downloading, isFalse);
    expect(download.message, contains('校验失败'));
    expect(directory.listSync(), isEmpty);
    download.dispose();
    dio.close();
  });
  test('valid official download becomes available only after IPA validation', () async {
    final dio = Dio()..httpClientAdapter = _BytesAdapter(_ipa());
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    await download.download(_release());
    expect(download.file, isNotNull);
    expect(await download.file!.exists(), isTrue);
    expect(download.hashVerified, isFalse);
    expect(download.message, contains('未提供 SHA256'));
    download.cancel();
    expect(await download.file!.exists(), isTrue);
    download.dispose();
    dio.close();
  });
  test('HTTP failure does not expose a partial IPA', () async {
    final dio = Dio()..httpClientAdapter = _BytesAdapter(_ipa(), status: 403);
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    await download.download(_release());
    expect(download.file, isNull);
    expect(download.message, contains('下载失败'));
    expect(directory.listSync(), isEmpty);
    download.dispose();
    dio.close();
  });
  test('cancelled download never publishes a file or leaves a partial IPA', () async {
    final dio = Dio()..httpClientAdapter = _WaitingAdapter();
    final download = IpaDownload(dio: dio, stagingDirectory: () async => directory);
    final pending = download.download(_release());
    // Wait for request to start, then cancel through the public action.
    await Future<void>.delayed(Duration.zero);
    download.cancel();
    await pending;
    expect(download.file, isNull);
    expect(download.downloading, isFalse);
    expect(directory.listSync(), isEmpty);
    download.dispose();
    dio.close();
  });
}
List<int> _ipa() => ZipEncoder().encode(Archive()
  ..addFile(ArchiveFile('Payload/CyShine.app/Info.plist', 8, [98,112,108,105,115,116,48,48])));
AppRelease _release({String? digest, int? build}) => AppRelease(version: Version(2, 0, 9),
  ipaSha256: digest, buildNumber: build,
  tagName: 'ios-v2.0.9', title: 'test',
  pageUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/tag/ios-v2.0.9'),
  ipaUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/download/ios-v2.0.9/CyShineMusic-unsigned.ipa'));
class _WaitingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancelFuture) async {
    await cancelFuture;
    throw DioException(requestOptions: options, type: DioExceptionType.cancel);
  }
  @override
  void close({bool force = false}) {}
}

const _infoPath = 'Payload/CyShine.app/Info.plist';

// Build small real ZIP32 records directly: Archive merges duplicate names and
// cannot generate the deliberately contradictory headers these tests exercise.
List<int> _zipFixture({
  List<String> names = const [_infoPath],
  List<int> data = const [98, 112, 108, 105, 115, 116, 48, 48],
  int method = 0,
  int mode = 0x81a4,
  int flags = 0,
  int? declaredSize,
  int? localSize,
  int? crc,
  List<int>? compressedData,
}) {
  final payload = compressedData ??
      (method == 8 ? ZLibEncoder(raw: true).convert(data) : data);
  final size = declaredSize ?? data.length;
  final checksum = crc ?? getCrc32(data);
  final local = BytesBuilder();
  final central = BytesBuilder();
  void word(BytesBuilder output, int value) {
    final bytes = ByteData(2)..setUint16(0, value, Endian.little);
    output.add(bytes.buffer.asUint8List());
  }
  void dword(BytesBuilder output, int value) {
    final bytes = ByteData(4)..setUint32(0, value, Endian.little);
    output.add(bytes.buffer.asUint8List());
  }
  for (final name in names) {
    final encoded = utf8.encode(name);
    final offset = local.length;
    dword(local, 0x04034b50);
    for (final value in [20, flags, method, 0, 0]) { word(local, value); }
    for (final value in [
      (flags & 8) != 0 ? 0 : checksum,
      (flags & 8) != 0 ? 0 : payload.length,
      localSize ?? ((flags & 8) != 0 ? 0 : size),
    ]) { dword(local, value); }
    word(local, encoded.length);
    word(local, 0);
    local.add(encoded);
    local.add(payload);
    if ((flags & 8) != 0) {
      for (final value in [0x08074b50, checksum, payload.length, size]) { dword(local, value); }
    }
    dword(central, 0x02014b50);
    for (final value in [0x314, 20, flags, method, 0, 0]) { word(central, value); }
    for (final value in [checksum, payload.length, size]) { dword(central, value); }
    for (final value in [encoded.length, 0, 0, 0, 0]) { word(central, value); }
    dword(central, mode << 16);
    dword(central, offset);
    central.add(encoded);
  }
  final directoryOffset = local.length;
  final directorySize = central.length;
  local.add(central.takeBytes());
  dword(local, 0x06054b50);
  for (final value in [0, 0, names.length, names.length]) { word(local, value); }
  dword(local, directorySize);
  dword(local, directoryOffset);
  word(local, 0);
  return local.takeBytes();
}

class _UndeletableFile implements File {
  @override
  Future<bool> exists() async => true;
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw const FileSystemException('simulated cleanup failure');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes, {this.status = 200});
  final List<int> bytes;
  final int status;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancelFuture) async => ResponseBody.fromBytes(bytes, status,
        headers: {Headers.contentLengthHeader: ['${bytes.length}']});
  @override
  void close({bool force = false}) {}
}
