// 仅导出桌面 Widget；系统媒体岛由 audio_service / NowPlaying 驱动。
// 旧 LiveActivityWidget 源码保留，但不再导出或创建自定义播放活动。
import SwiftUI
import WidgetKit

@main
struct CyShineMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        CyShineHomeWidget()
    }
}
