import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' show InputFileStream, ZipFileHeader, getCrc32;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/dio_factory.dart';
import '../../core/services/app_logger.dart';
import '../../core/services/app_update_service.dart';
import '../../core/storage/settings_store.dart';

final ipaDownloadProvider = ChangeNotifierProvider<IpaDownload>((ref) {
  final adapter = ref.watch(settingsProvider.select((s) => s.networkAdapterMode));
  final dio = createDio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'User-Agent': 'CyShineMusic'},
  ), adapterMode: adapter);
  ref.onDispose(() => dio.close(force: true));
  return IpaDownload(dio: dio, stagingDirectory: () async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/app-update-staging')..createSync(recursive: true);
  });
});

const _maximumIpaBytes = 512 * 1024 * 1024;

/// Inspect every ZIP header before decoding; never extract or buffer a full entry.
Future<bool> validateIpaFile(String path, {String? expectedSha256}) => Isolate.run(() async {
  final input = InputFileStream(path);
  try {
    final entries = _inspectIpaZip(input);
    for (final entry in entries) {
      final header = entry.header;
      final counter = _IpaCrcSink(header.uncompressedSize);
      final Sink<List<int>> sink = header.compressionMethod == 8
          ? ZLibDecoder(raw: true).startChunkedConversion(counter)
          : counter;
      try {
        await for (final chunk in File(path).openRead(
            entry.dataOffset, entry.dataOffset + header.compressedSize)) {
          sink.add(chunk);
        }
        sink.close();
      } catch (_) {
        // Closing a failed codec can throw again; preserve the first failure.
        try { sink.close(); } catch (_) {}
        rethrow;
      }
      if (counter.size != header.uncompressedSize || counter.crc != header.crc32) {
        throw const FormatException('IPA ZIP size or CRC mismatch');
      }
    }
    if (expectedSha256 != null) {
      final actual = await sha256.bind(File(path).openRead()).first;
      if (actual.toString() != expectedSha256.toLowerCase()) {
        throw const FormatException('IPA SHA256 mismatch');
      }
    }
    return expectedSha256 != null;
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Invalid IPA ZIP: $error');
  } finally {
    await input.close();
  }
});

class _IpaCrcSink implements Sink<List<int>> {
  _IpaCrcSink(this.limit);
  final int limit;
  int size = 0;
  int crc = 0;

  @override
  void add(List<int> chunk) {
    size += chunk.length;
    // Synchronous decoder output: stop before CRC work or queued output grows.
    if (size > limit) {
      throw const FormatException('IPA expanded size exceeds declared limit');
    }
    crc = getCrc32(chunk, crc);
  }

  @override
  void close() {}
}

class _IpaZipEntry {
  const _IpaZipEntry(this.header, this.dataOffset, this.end);
  final ZipFileHeader header;
  final int dataOffset;
  final int end;
}

List<_IpaZipEntry> _inspectIpaZip(InputFileStream input) {
  Never invalid() => throw const FormatException('Unsafe or invalid IPA ZIP headers');
  final length = input.length;
  if (length < 22 || length > _maximumIpaBytes) invalid();
  // Official IPAs are ZIP32. Reject split/ZIP64 archives rather than guessing
  // descriptor widths; cap directory work before invoking the header parser.
  final tailStart = length > 65557 ? length - 65557 : 0;
  final tail = input.subset(position: tailStart).toUint8List();
  final view = ByteData.sublistView(tail);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + view.getUint16(i + 20, Endian.little) == tail.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) invalid();
  int word(int offset) => view.getUint16(eocd + offset, Endian.little);
  int dword(int offset) => view.getUint32(eocd + offset, Endian.little);
  final count = word(10);
  final directorySize = dword(12);
  final directoryOffset = dword(16);
  if (word(4) != 0 || word(6) != 0 || word(8) != count ||
      count == 0 || count > 20000 || directorySize > 8 * 1024 * 1024 ||
      directoryOffset + directorySize != tailStart + eocd) invalid();
  final directory = input.subset(position: directoryOffset, length: directorySize);
  final entries = <_IpaZipEntry>[];
  final names = <String>{};
  var total = 0;
  var hasInfo = false;
  for (var i = 0; i < count; i++) {
    if (directory.length < 46 || directory.readUint32() != 0x02014b50) invalid();
    // No fileBytes: ZipFileHeader.read parses metadata only, never content.
    final header = ZipFileHeader()..read(directory);
    final name = header.filename;
    final isDirectory = name.endsWith('/');
    final path = isDirectory ? name.substring(0, name.length - 1) : name;
    final mode = (header.externalFileAttributes >> 16) & 0xf000;
    if (path.isEmpty || path.contains(RegExp(r'[\\\x00-\x1f\x7f:]')) ||
        path.split('/').any((part) => part.isEmpty || part == '.' || part == '..') ||
        !names.add(path.toLowerCase()) ||
        (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
        (mode == 0x4000 && !isDirectory) ||
        ((header.externalFileAttributes & 0x10) != 0 && !isDirectory) ||
        header.versionNeededToExtract > 20 || header.diskNumberStart != 0 ||
        (header.generalPurposeBitFlag & ~0x80e) != 0 ||
        (header.compressionMethod != 0 && header.compressionMethod != 8) ||
        header.compressedSize < 0 || header.compressedSize > _maximumIpaBytes ||
        header.uncompressedSize < 0 || header.uncompressedSize > _maximumIpaBytes ||
        (isDirectory && header.uncompressedSize != 0) ||
        (total += header.uncompressedSize) > 1024 * 1024 * 1024) invalid();
    hasInfo |= !isDirectory && RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(name);
    final offset = header.localHeaderOffset;
    if (offset < 0 || offset + 30 > directoryOffset) invalid();
    final local = input.subset(position: offset, length: directoryOffset - offset);
    if (local.readUint32() != 0x04034b50 || local.readUint16() > 20 ||
        local.readUint16() != header.generalPurposeBitFlag ||
        local.readUint16() != header.compressionMethod) invalid();
    local.skip(4); // DOS modification time/date.
    final crc = local.readUint32();
    final compressed = local.readUint32();
    final expanded = local.readUint32();
    final nameLength = local.readUint16();
    final extraLength = local.readUint16();
    if (nameLength + extraLength > local.length ||
        local.readString(size: nameLength) != name) invalid();
    local.skip(extraLength);
    final dataOffset = offset + local.position;
    var end = dataOffset + header.compressedSize;
    if (end > directoryOffset) invalid();
    final descriptor = (header.generalPurposeBitFlag & 8) != 0;
    if (descriptor) {
      if ((crc != 0 && crc != header.crc32) ||
          (compressed != 0 && compressed != header.compressedSize) ||
          (expanded != 0 && expanded != header.uncompressedSize)) invalid();
      final data = input.subset(position: end, length: directoryOffset - end);
      if (data.length < 12) invalid();
      var actualCrc = data.readUint32();
      if (actualCrc == 0x08074b50) {
        if (data.length < 12) invalid();
        actualCrc = data.readUint32();
      }
      if (actualCrc != header.crc32 || data.readUint32() != header.compressedSize ||
          data.readUint32() != header.uncompressedSize) invalid();
      end += data.position;
    } else if (crc != header.crc32 || compressed != header.compressedSize ||
        expanded != header.uncompressedSize) {
      invalid();
    }
    entries.add(_IpaZipEntry(header, dataOffset, end));
  }
  if (!directory.isEOS || !hasInfo) invalid();
  entries.sort((a, b) => a.header.localHeaderOffset.compareTo(b.header.localHeaderOffset));
  var end = 0;
  for (final entry in entries) {
    // Also reject overlapping/reused local records and unlisted hidden records.
    if (entry.header.localHeaderOffset != end) invalid();
    end = entry.end;
  }
  if (end != directoryOffset) invalid();
  return entries;
}

class IpaDownload extends ChangeNotifier {
  IpaDownload({required Dio dio, required Future<Directory> Function() stagingDirectory})
      : _dio = dio, _stagingDirectory = stagingDirectory;
  final Dio _dio;
  final Future<Directory> Function() _stagingDirectory;
  static final _activeStagingFiles = <Uri>{};
  static final _stagedIpaName = RegExp(r'^pending-(\d+)\.ipa$');
  CancelToken? _cancelToken;
  bool _disposed = false;
  bool downloading = false;
  double? progress;
  File? file;
  String? releaseTag;
  int? releaseBuildNumber;
  String? releaseSha256;
  String? message;
  bool hashVerified = false;

  Future<void> download(AppRelease release) async {
    if (downloading || _disposed) return;
    final uri = release.ipaUri;
    if (!isOfficialUpdateAssetUri(uri, tagName: release.tagName)) {
      message = '未找到唯一可信的官方 IPA，请查看官方发行版';
      _notify();
      return;
    }
    final token = CancelToken();
    _cancelToken = token;
    downloading = true;
    progress = null;
    message = '正在下载 IPA…';
    _notify();
    File? partial;
    Uri? stagingUri;
    try {
      final directory = await _stagingDirectory();
      if (token.isCancelled) throw token.cancelError!;
      final startedAt = DateTime.now().microsecondsSinceEpoch;
      partial = File('${directory.path}/pending-$startedAt.ipa');
      stagingUri = partial.uri;
      _activeStagingFiles.add(stagingUri);
      final response = await _dio.download(uri.toString(), partial.path,
        cancelToken: token,
        options: Options(validateStatus: (status) => status == 200),
        onReceiveProgress: (received, total) {
          if (received > _maximumIpaBytes || total > _maximumIpaBytes) {
            token.cancel('IPA exceeds size limit');
            return;
          }
          if (token.isCancelled) return;
          progress = total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
          _notify();
        },
      );
      if (response.statusCode != 200 || !_isAssetResponseUri(response.realUri)) {
        throw const FormatException('Invalid IPA HTTP response');
      }
      if (token.isCancelled) throw token.cancelError!;
      String? expectedHash = release.ipaSha256;
      if (expectedHash != null && (expectedHash.length != 64 ||
          !RegExp(r'^[a-fA-F0-9]+$').hasMatch(expectedHash))) {
        throw const FormatException('Invalid official manifest SHA256');
      }
      final checksum = release.sha256Uri;
      if (expectedHash == null && release.hasSha256 && checksum == null) {
        throw const FormatException('Official SHA256 attachment is ambiguous or untrusted');
      }
      if (expectedHash == null && checksum != null) {
        if (!isOfficialUpdateAssetUri(checksum, tagName: release.tagName,
            fileName: '$iosUpdateIpaName.sha256')) {
          throw const FormatException('Untrusted checksum URL');
        }
        final checksumResponse = await _dio.get<String>(checksum.toString(),
          cancelToken: token,
          options: Options(responseType: ResponseType.plain,
            validateStatus: (status) => status == 200),
        );
        if (checksumResponse.statusCode != 200 || !_isAssetResponseUri(checksumResponse.realUri)) {
          throw const FormatException('Invalid checksum HTTP response');
        }
        expectedHash = checksumResponse.data?.trim().split(RegExp(r'\s+')).first;
        if (expectedHash == null || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
          throw const FormatException('Invalid official SHA256 attachment');
        }
      }
      if (token.isCancelled) throw token.cancelError!;
      message = '下载完成，正在校验 IPA…';
      _notify();
      final verified = await validateIpaFile(partial.path, expectedSha256: expectedHash);
      if (token.isCancelled) throw token.cancelError!;
      // Prune app-owned packages only after a new package passes validation.
      final previous = file;
      file = partial;
      partial = null;
      if (previous != null) await _removeStagingFile(previous);
      await _removeOldStagingFiles(directory, startedAt);
      releaseTag = release.tagName;
      releaseBuildNumber = release.buildNumber;
      releaseSha256 = release.ipaSha256;
      hashVerified = verified;
      message = verified
          ? 'IPA 与官方 SHA256 一致；可另存或分享安装'
          : 'IPA 结构与 CRC 校验通过；官方未提供 SHA256';
    } catch (error) {
      await AppLogger.write('update', 'IPA download/validation failed: $error');
      message = token.isCancelled ? '已取消下载' :
          error is FormatException ? 'IPA 下载或校验失败，请重新下载或查看官方发行版' :
          '下载失败，请检查网络或存储空间后重试';
    } finally {
      try {
        if (partial != null) await _removeStagingFile(partial);
      } finally {
        _activeStagingFiles.remove(stagingUri);
        _cancelToken = null;
        downloading = false;
        _notify();
      }
    }
  }

  Future<void> _removeOldStagingFiles(Directory directory, int startedAt) async {
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File || _activeStagingFiles.contains(entry.uri)) continue;
        final match = _stagedIpaName.firstMatch(entry.uri.pathSegments.last);
        final timestamp = int.tryParse(match?.group(1) ?? '');
        if (timestamp != null && timestamp < startedAt) {
          await _removeStagingFile(entry);
        }
      }
    } catch (error) {
      await AppLogger.write('update', 'IPA staging cleanup failed: $error');
    }
  }

  Future<void> _removeStagingFile(File staged) async {
    try {
      if (await staged.exists()) await staged.delete();
    } catch (error) {
      await AppLogger.write('update', 'IPA staging cleanup failed: $error');
    }
  }

  void cancel() { _cancelToken?.cancel('User left settings or cancelled'); }
  void _notify() { if (!_disposed) notifyListeners(); }
  @override
  void dispose() { _disposed = true; cancel(); super.dispose(); }
}

bool _isAssetResponseUri(Uri uri) => uri.scheme == 'https' &&
    const {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}
        .contains(uri.host);
