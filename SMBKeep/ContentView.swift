/*
许可信息见本示例的 LICENSE.txt 文件。

摘要：
App 的主 SwiftUI 视图。
*/

import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        if AppDelegate.launchedAsLoginItem {
            // 静默的登录项启动：不渲染任何内容，并关闭 SwiftUI 场景创建的窗口。
            // 自动挂载在 AppDelegate 中执行。
            Color.clear
                .frame(width: 1, height: 1)
                .background(WindowCloser())
        } else {
            ConnectionListView()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}

/// 视图一出现就关闭承载它的窗口。用于让登录项启动完全无界面。
private struct WindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            view?.window?.close()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
