// 桌面 Widget 播放状态与封面同步（沿用 cy_shine_music/live_activity 通道）。
// start/update 只写 App Group；end 只标记未播放并保留上一曲元数据。
// 系统媒体岛由 audio_service / NowPlaying 单写，本桥接不创建或更新播放活动。
// 保留 CyShineActivityAttributes.swift 编译，用于启动时清理旧版残留活动。

import ActivityKit
import Flutter
import Foundation
import UIKit
import WidgetKit

@available(iOS 16.2, *)
final class CyShineLiveActivityBridge: NSObject {

  static let channelName = "cy_shine_music/live_activity"
  static let urlScheme = "cyshinemusic"

  /// 与 MusicHomeWidgetPlugin / Widget 扩展里保持一致。
  static let appGroupIdentifier = "group.com.cyshine.music"
  private static let sharedContainerURL = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: appGroupIdentifier)

  private static let artworkDirectory = "artwork"
  private static let maxArtworkPixels: CGFloat = 256

  private var channel: FlutterMethodChannel?
  private var lastArgs: [String: Any]?
  private var artworkPath: String?

  // MARK: - 注册

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = CyShineLiveActivityBridge()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    instance.channel = channel
    channel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    // 进程启动时清掉上次残留的活动（避免灵动岛上挂着一条已经过期的）
    instance.endOrphanedActivities()
    CyShineNativeLog.write("widget-sync", Self.diagnostics())
    // 保持存活：通道回调是 weak 的，所以这里让 AppDelegate 侧持有
    shared = instance
  }

  /// 由 AppDelegate 持有，保证回调期间实例不被释放。
  private(set) static var shared: CyShineLiveActivityBridge?

  // MARK: - 通道（保留旧方法名，现仅同步桌面 Widget）

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      CyShineNativeLog.write("widget-sync", Self.diagnostics())
      result(Self.sharedContainerURL != nil)

    case "start", "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少播放状态", details: nil))
        return
      }
      do {
        try syncSharedPlayback(args)
        result(true)
      } catch {
        result(FlutterError(code: "WIDGET_SYNC_FAILED",
                            message: error.localizedDescription, details: Self.describe(error)))
      }

    case "end":
      // 异步封面完成后也只能补写未播放状态，不能恢复旧播放状态。
      lastArgs?["playing"] = false
      markWidgetStopped()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func diagnostics() -> String {
    let available = Self.sharedContainerURL != nil
    return "自定义播放活动已禁用；系统媒体由 audio_service 管理；Widget共享同步=\(available ? "可用" : "不可用（AppGroup不可用）")"
  }

  /// 由 AppDelegate / SceneDelegate 在收到 `cyshinemusic://…` 时调用。
  /// 返回 true 表示这个 URL 由本桥接消费掉了。
  @discardableResult
  func handleIncomingURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == Self.urlScheme else { return false }
    let host = url.host?.lowercased() ?? ""
    guard host == "player" else { return false }
    let action: String?
    switch (host, url.lastPathComponent.lowercased()) {
    case (_, "toggle"), ("player", "toggle"): action = "toggle"
    case (_, "previous"), ("player", "previous"): action = "previous"
    case (_, "next"), ("player", "next"): action = "next"
    default: action = nil
    }
    if let action {
      // 只在真的带动作时才派发；单纯打开播放器交给路由处理。
      channel?.invokeMethod("control", arguments: action)
    } else {
      channel?.invokeMethod("openPlayer", arguments: nil)
    }
    return true
  }

  // MARK: - 旧活动迁移清理与 Widget 同步

  private func endOrphanedActivities() {
    let previousActivities = Activity<CyShineActivityAttributes>.activities
    Task { @MainActor in
      for previous in previousActivities {
        await previous.end(nil, dismissalPolicy: .immediate)
      }
      CyShineNativeLog.write("widget-sync", "自定义播放活动已禁用；旧活动清理数=\(previousActivities.count)")
    }
  }

  private func syncSharedPlayback(_ args: [String: Any]) throws {
    guard let trackId = args["trackId"] as? String, !trackId.isEmpty else {
      throw NSError(domain: "CyShineLiveActivity", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "缺少曲目标识"])
    }
    let artworkChanged = lastArgs?["trackId"] as? String != trackId
      || lastArgs?["cover"] as? String != args["cover"] as? String
    if artworkChanged { artworkPath = nil }
    lastArgs = args
    writeSharedState(args: args, artworkPath: artworkPath)
    if artworkChanged { resolveArtworkForCurrent(args) }
  }

  private static func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
  }

  // MARK: - 封面

  /// 异步解码封面并写入 App Group，仅刷新桌面 Widget。
  private func resolveArtworkForCurrent(_ args: [String: Any]) {
    guard let trackId = args["trackId"] as? String, !trackId.isEmpty else { return }
    let cover = (args["cover"] as? String) ?? ""
    let headers = (args["headers"] as? [String: Any])?
      .reduce(into: [String: String]()) { acc, e in acc[e.key] = String(describing: e.value) } ?? [:]

    guard !cover.isEmpty, let base = Self.sharedContainerURL else { return }
    Task.detached(priority: .utility) { [weak self] in
      guard let self, let jpeg = Self.artworkData(cover: cover, headers: headers) else { return }
      await MainActor.run {
        guard let args = self.lastArgs,
              args["trackId"] as? String == trackId, args["cover"] as? String == cover else { return }
        let directory = base.appendingPathComponent(Self.artworkDirectory, isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try jpeg.write(to: directory.appendingPathComponent("current.jpg"), options: .atomic)
        } catch {
          return
        }
        self.artworkPath = "\(Self.artworkDirectory)/current.jpg"
        self.writeSharedState(args: args, artworkPath: self.artworkPath)
      }
    }
  }

  private static func artworkData(cover: String, headers: [String: String]) -> Data? {
    let data: Data?
    if let url = URL(string: cover), url.isFileURL {
      data = try? Data(contentsOf: url)
    } else if let url = URL(string: cover), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" {
      data = downloadSynchronously(url: url, headers: headers)
    } else {
      data = try? Data(contentsOf: URL(fileURLWithPath: cover))
    }
    guard let data, let image = UIImage(data: data),
          let scaled = downscale(image, maxPixels: maxArtworkPixels) else { return nil }
    return scaled.jpegData(compressionQuality: 0.82)
  }

  private static func downloadSynchronously(
    url: URL,
    headers: [String: String]
  ) -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let semaphore = DispatchSemaphore(value: 0)
    var output: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      output = data
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return output
  }

  private static func downscale(_ image: UIImage, maxPixels: CGFloat) -> UIImage? {
    let side = max(image.size.width, image.size.height)
    guard side > 0 else { return nil }
    let scale = min(1, maxPixels / side)
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }

  // MARK: - 给桌面小组件用的共享数据

  private func writeSharedState(args: [String: Any], artworkPath: String?) {
    guard Self.sharedContainerURL != nil,
          let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) else { return }
    let metadata = [
      "widget.trackId": args["trackId"] as? String ?? "",
      "widget.title": args["title"] as? String ?? "",
      "widget.artist": args["artist"] as? String ?? "",
      "widget.artworkFile": artworkPath ?? "",
    ]
    let playing = args["playing"] as? Bool ?? false
    guard defaults.bool(forKey: "widget.playing") != playing ||
      metadata.contains(where: { defaults.string(forKey: $0.key) != $0.value }) else { return }
    for (key, value) in metadata { defaults.set(value, forKey: key) }
    defaults.set(playing, forKey: "widget.playing")
    reloadHomeWidget(defaults)
  }

  private func markWidgetStopped() {
    guard Self.sharedContainerURL != nil,
          let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
          defaults.bool(forKey: "widget.playing") else { return }
    defaults.set(false, forKey: "widget.playing")
    reloadHomeWidget(defaults)
  }

  private func reloadHomeWidget(_ defaults: UserDefaults) {
    defaults.set(Date().timeIntervalSince1970, forKey: "widget.updatedAt")
    WidgetCenter.shared.reloadTimelines(ofKind: "CyShineHomeWidget")
  }

}
