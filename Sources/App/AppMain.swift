//
//  AppMain.swift — 入口（菜单栏由 AppDelegate 管理）
//

import SwiftUI

@main
struct GHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 纯菜单栏应用：可见窗口由 AppDelegate 的 NSPopover 提供，
        // 这里只挂一个空的 Settings 场景以满足 App 协议（⌘, 不会用到）。
        Settings {
            EmptyView()
        }
    }
}
