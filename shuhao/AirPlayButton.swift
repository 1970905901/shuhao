import SwiftUI
import AVKit

/// AVRoutePickerView 的 SwiftUI 包装 —— 点击弹出系统 AirPlay / 输出设备选择器。
/// 系统强制用它自己的按钮(不能用自定义 Button 触发 picker),所以只暴露
/// tint 让它融入播放页的浅色图标风格。
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = UIColor.white.withAlphaComponent(0.6)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = UIColor(named: "AccentColor") ?? .systemPink
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
    }
}
