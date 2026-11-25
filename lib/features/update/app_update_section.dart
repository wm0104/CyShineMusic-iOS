import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../core/services/app_logger.dart';
import '../../core/services/app_update_service.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../../theme/app_motion.dart';
import '../settings/widgets/settings_style.dart';
import 'app_update_controller.dart';
import 'ipa_download.dart';

class AppUpdateSection extends ConsumerStatefulWidget {
  const AppUpdateSection({super.key});
  @override
  ConsumerState<AppUpdateSection> createState() => _AppUpdateSectionState();
}

class _AppUpdateSectionState extends ConsumerState<AppUpdateSection> {
  bool _expanded = false;
  bool _opening = false;
  bool _exporting = false;
  GoRouter? _router;
  IpaDownload? _download;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(appUpdateControllerProvider).initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.of(context);
    if (_router != router) {
      _router?.routeInformationProvider.removeListener(_routeChanged);
      _router = router;
      router.routeInformationProvider.addListener(_routeChanged);
    }
  }

  // Settings is retained by the indexed shell, so dispose alone is insufficient.
  void _routeChanged() {
    if (_router?.routeInformationProvider.value.uri.path != '/settings') {
      _download?.cancel();
    }
  }

  @override
  void dispose() {
    _router?.routeInformationProvider.removeListener(_routeChanged);
    _download?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _expanded = true);
    await ref.read(appUpdateControllerProvider).check();
  }

  Future<void> _open(Uri uri) async {
    try {
      final opened = await ref.read(externalUriLauncherProvider)(uri);
      if (!opened && mounted) showAppToast(context, '无法打开链接，请稍后重试', type: AppToastType.warning);
    } catch (error) {
      await AppLogger.write('update', 'open release failed: $error');
      if (mounted) showAppToast(context, '无法打开官方发行版', type: AppToastType.warning);
    }
  }

  Future<void> _trollStore(AppRelease release) async {
    if (_opening || release.ipaUri == null) return;
    setState(() => _opening = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      if (!(prefs.getBool('ios_update_trollstore_acknowledged') ?? false)) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('使用 TrollStore 更新'),
            content: const Text('请先在 TrollStore 设置中启用 URL Scheme，并按提示应用设置。'
                '未安装或未启用时可能打开放大器。TrollStore 将自行下载官方 IPA 并处理安装，'
                '不经过本 App 的本地校验；也可取消后下载 IPA，再分享安装。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续')),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await prefs.setBool('ios_update_trollstore_acknowledged', true);
      }
      if (!mounted) return;
      final opened = await ref.read(externalUriLauncherProvider)(trollStoreInstallUri(release.ipaUri!));
      if (mounted) showAppToast(context, opened
          ? '已请求打开，请在 TrollStore 查看安装结果；若打开放大器，请启用 URL Scheme 或下载 IPA'
          : '无法打开 TrollStore，请启用 URL Scheme，或下载 IPA / 查看官方发行版',
          type: opened ? AppToastType.info : AppToastType.warning);
    } catch (error) {
      await AppLogger.write('update', 'TrollStore dispatch failed: $error');
      if (mounted) showAppToast(context, '无法打开 TrollStore，可下载 IPA 或查看官方发行版', type: AppToastType.warning);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _save(IpaDownload download) async {
    final file = download.file;
    if (_exporting || file == null) return;
    setState(() => _exporting = true);
    try {
      final saved = await const MethodChannel('cy_shine_music/audio_intent')
          .invokeMethod<bool>('saveUpdateIpa', {'path': file.path});
      if (mounted && saved == true) {
        showAppToast(context, '已导出到你选择的位置', type: AppToastType.success);
      }
    } catch (error) {
      await AppLogger.write('update', 'IPA export failed: $error');
      if (mounted) showAppToast(context, '保存失败，可使用分享中的“存储到文件”', type: AppToastType.warning);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(IpaDownload download) async {
    final file = download.file;
    if (_exporting || file == null) return;
    setState(() => _exporting = true);
    try {
      await const MethodChannel('cy_shine_music/audio_intent').invokeMethod<bool>('openAudio', {'path': file.path});
      // Opening a share sheet is neither a saved file nor a successful installation.
    } catch (error) {
      await AppLogger.write('update', 'IPA share failed: $error');
      if (mounted) showAppToast(context, '无法分享，请尝试保存到文件', type: AppToastType.warning);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(appUpdateControllerProvider);
    final download = ref.watch(ipaDownloadProvider);
    _download = download;
    final release = update.release;
    final version = ref.watch(packageInfoProvider).maybeWhen(
      data: (value) => '$appDisplayName ${value.version}', orElse: () => '读取中…');
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expanded || release != null;
    final busy = update.checking || download.downloading || _opening || _exporting;
    final hasFile = download.file != null && download.releaseTag == release?.tagName &&
        download.releaseBuildNumber == release?.buildNumber && download.releaseSha256 == release?.ipaSha256;
    final textButtonStyle = TextButton.styleFrom(textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal));
    final mainButtonText = const TextStyle(fontSize: 14, fontWeight: FontWeight.normal);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(color: Colors.transparent, child: InkWell(
        borderRadius: BorderRadius.circular(20),
        key: const ValueKey('check-update-setting'),
        onTap: busy ? null : () {
          if (!expanded) { unawaited(_check()); }
          else { setState(() => _expanded = !_expanded); }
        },
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14), child: Row(children: [
          const SettingsSymbolBubble(icon: Icons.system_update_alt_rounded),
          const SizedBox(width: 18),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('在线更新', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 5),
            Text('当前版本：$version', style: TextStyle(fontSize: 12, color: scheme.outline)),
          ])),
          if (release != null) Icon(Icons.circle, size: 7, color: scheme.primary),
        ])),
      )),
      AnimatedSize(duration: AppMotion.medium, curve: AppMotion.emphasized,
        alignment: Alignment.topCenter,
        child: !expanded ? const SizedBox.shrink() : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            if (release != null) ...[
              Row(children: [
                Expanded(child: Text('●  发现新版本', style: TextStyle(color: scheme.primary, fontSize: 12))),
                Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: scheme.secondaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(16)),
                  child: Text('正式版', style: TextStyle(fontSize: 11, color: scheme.primary))),
              ]),
              const SizedBox(height: 6),
              Text(release.displayVersion, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
              const SizedBox(height: 24),
              Text('更新说明', style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 8),
              Text(_shortNotes(release), style: const TextStyle(fontSize: 13, height: 1.5), maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 24),
              if (release.ipaUri != null) ...[
                FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), textStyle: mainButtonText),
                  onPressed: busy ? null : () => _trollStore(release), child: const Text('TrollStore 更新安装')),
                const SizedBox(height: 10),
                FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), textStyle: mainButtonText),
                  onPressed: busy ? null : () => download.download(release), child: const Text('下载 IPA')),
                const SizedBox(height: 10),
                Text('下载完成后可保存和分享安装', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: scheme.outline)),
              ] else Text('未找到唯一可信的官方 IPA，可前往官方发行版查看。', style: TextStyle(fontSize: 13, color: scheme.outline)),
              if (download.downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: download.progress),
                const SizedBox(height: 6),
                Text(download.progress == null ? '正在下载 / 校验…' : '${(download.progress! * 100).toStringAsFixed(0)}%', textAlign: TextAlign.center),
                TextButton(onPressed: download.cancel, child: const Text('取消下载')),
              ],
              if (hasFile && !download.downloading) ...[
                const SizedBox(height: 8),
                Text('已暂存于 App，尚未另存到你的文件', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: scheme.outline)),
                Row(children: [
                  Expanded(child: TextButton(onPressed: busy ? null : () => _save(download), child: const Text('保存到文件'))),
                  Expanded(child: TextButton(onPressed: busy ? null : () => _share(download), child: const Text('分享安装'))),
                ]),
              ],
              if (download.message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(download.message!, style: TextStyle(fontSize: 11, color: scheme.outline), textAlign: TextAlign.center)),
            ],
            if (update.checking) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('正在检查更新…', textAlign: TextAlign.center)),
            if (update.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(update.message!, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant), textAlign: TextAlign.center)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(style: textButtonStyle, onPressed: busy ? null : _check, child: const Text('重新检查')),
              Text('  │  ', style: TextStyle(color: scheme.outlineVariant)),
              TextButton(style: textButtonStyle, onPressed: () => _open(release?.pageUri ?? Uri.parse('https://github.com/$iosUpdateRepository/releases/latest')), child: const Text('官方发行版')),
            ]),
            if (release != null) Text('已保留更新信息，等待安装\n缓存不代表下载链接仍可用，可手动重新检查', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, height: 1.5, color: scheme.outline)),
          ],
        ),
      ),
    ]);
  }
}

String _shortNotes(AppRelease release) {
  final lines = release.notes.split('\n').map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#') && !line.startsWith('```'));
  final text = lines.take(2).join('\n');
  if (text.isEmpty) return '此版本的完整更新说明请查看官方发行版。';
  return text.length > 140 ? '${text.substring(0, 140)}…' : text;
}
