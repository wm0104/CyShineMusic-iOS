// 静态回归守卫：自定义播放活动停用，保留旧活动迁移清理与桌面 Widget 同步。
// 不代替 Swift 编译、Flutter 测试或 iOS 真机验收。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFileSync(join(root, path), 'utf8');
const bridge = read('ios/Runner/CyShineLiveActivityBridge.swift');
const service = read('lib/features/player/live_activity_service.dart');
const bundle = read('ios/CyShineMusicWidget/CyShineWidgetBundle.swift');
const plugin = read('ios/Runner/CyShineNativePlugin.swift');
const main = read('lib/main.dart');
const failures = [];
const check = (ok, message) => { if (!ok) failures.push(message); };

check(!/Activity(?:<[^>]+>)?\s*\.request\s*\(/.test(bridge), '不得创建 ActivityKit 播放活动');
check(!/\.update\s*\(/.test(bridge), '桥接不得更新 ActivityKit 播放活动');
check(!/requestAuthorization|ActivityAuthorizationInfo|authorizationResolved|pendingStart|observeForeground/.test(bridge + service), 'Widget 同步不得依赖活动授权、通知弹窗或前台补发');
check(/instance\.endOrphanedActivities\(\)/.test(bridge), '注册时必须清理旧活动');
const cleanup = bridge.match(/private func endOrphanedActivities\(\)[\s\S]*?(?=\n  private func)/)?.[0] ?? '';
check(/Activity<CyShineActivityAttributes>\.activities/.test(cleanup) && /await previous\.end\(nil, dismissalPolicy: \.immediate\)/.test(cleanup), '必须枚举本应用旧 Attributes 活动并立即结束');
check(!/guard|sharedContainerURL|Authorization/.test(cleanup), '旧活动清理不得受 AppGroup 或授权限制');
check(/result\(Self\.sharedContainerURL != nil\)/.test(bridge), 'isSupported 应只表示共享同步能力');
for (const token of ['case "start", "update":', 'case "end":', 'syncSharedPlayback(args)', 'widget.artworkFile', 'writeSharedState', 'resolveArtworkForCurrent', 'jpeg.write', 'WidgetCenter.shared.reloadTimelines']) {
  check(bridge.includes(token), `保留桌面 Widget 契约：${token}`);
}
check(/defaults\.set\(false, forKey: "widget.playing"\)/.test(bridge), '停止需只标记未播放');
const stopped = bridge.match(/private func markWidgetStopped\(\)[\s\S]*?(?=\n  private func)/)?.[0] ?? '';
check(!/removeObject|widget\.(title|artist|artworkFile)/.test(stopped), '停止不得清空上一曲元数据或封面');
check(/lastArgs\?\["playing"\] = false/.test(bridge), '停止后异步封面补写必须仍为未播放');
check(/guard host == "player" else \{ return false \}/.test(bridge), '旧播放器深链不得吞掉外部音频导入');
check(/CyShineHomeWidget\(\)/.test(bundle) && !/CyShineLiveActivityWidget\(\)/.test(bundle), '扩展只能导出 HomeWidget');
check(/liveActivityProvider\)\.initialize\(\)/.test(main) && /ref\.listen<PlayerState>/.test(service), '不得禁用桌面同步 provider');
check(/payload\['title'\]/.test(service) && /payload\['artist'\]/.test(service) && /payload\['cover'\]/.test(service), '去重必须包含标题、歌手与封面');
check(/case 'control':/.test(service) && /case 'openPlayer':/.test(service) && /handleIncomingURL/.test(bridge), '保留旧播放器深链与控制回调');
check(!/extensionLoaded/.test(plugin), '配置列表不能用作扩展是否加载的判据');
check(!/MPNowPlayingInfoCenter|MPRemoteCommandCenter/.test(bridge + service), '系统媒体继续由 audio_service 单写');
check(/UIDeviceFamily/.test(read('ios/CyShineMusicWidget/Info.plist')), '保留 Widget 设备声明');

if (failures.length) {
  console.error(`✗ ${failures.length} 项不通过：\n${failures.map((f) => `  - ${f}`).join('\n')}`);
  process.exit(1);
}
console.log('✓ 自定义播放活动停用 / 旧活动清理 / Widget 状态与封面同步静态守卫通过（非真机验证）');
