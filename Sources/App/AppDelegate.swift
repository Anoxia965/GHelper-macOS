//
//  AppDelegate.swift — 菜单栏（NSStatusItem + NSPopover）+ 独立主窗口
//
//  形态：regular 应用（有 Dock 图标 + 菜单栏常驻 + 可停靠窗口）。
//   · 菜单栏图标：点开是快速面板（popover），顶部有「展开到独立窗口」。
//   · 独立窗口：点 Dock 图标 / 菜单栏的「展开」 打开，关窗只隐藏不退出。
//  （之前那版是纯 LSUIElement 菜单栏应用，无法开窗口，已废弃。）
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// AppModel 切回纯菜单栏模式时发，让 AppDelegate 让出前台
    static let ghelperResignFront = Notification.Name("cn.anoxia.GHelper.resignFront")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var titleTimer: Timer?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：避免手动双击 App 或多次拉起导致菜单栏出现两个图标
        let bid = Bundle.main.bundleIdentifier ?? "cn.anoxia.GHelper"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }

        let model = AppModel.shared

        // 界面形态：默认纯菜单栏（LSUIElement + .accessory），可在设置里切回程序坞图标。
        // 尽早设置，避免启动时 Dock 图标闪一下。
        model.applyActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resignFrontOnNotification),
            name: .ghelperResignFront,
            object: nil
        )

        // 弹出面板（菜单栏快速视图）：紧凑仪表盘，传入「展开到窗口」回调
        let popoverView = PopoverDashboard(showWindowAction: { [weak self] in self?.showMainWindow() })
            .environmentObject(model)
        let hosting = NSHostingController(rootView: popoverView)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 320, height: 580)
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "Menubar", withExtension: "pdf"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                // 菜单栏图标标准约 18pt，显式约束防止 PDF 原生尺寸过大
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)
                button.image?.isTemplate = true
            }
            button.toolTip = "GHelper"
            updateTitle(model.menuBarTitle)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 2.5s 刷新一次状态栏温度（与 AppModel 采样同步，温度是慢变量）
        titleTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateTitle(model.menuBarTitle)
            }
        }

        // 启动后静默检查一次更新（失败不打扰，发现新版才在顶部亮角标）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            UpdateChecker.shared.check(auto: true)
        }

        // 纯菜单栏启动（没有主窗口）时让出前台：.regular 策略下 App 启动即 frontmost，
        // 但没有窗口可交互，会吞掉用户的键盘输入（打字被截断）。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.resignFrontIfNoVisibleWindow()
        }
    }

    private func updateTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        button.attributedTitle = NSAttributedString(string: " " + title, attributes: attrs)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: 独立主窗口

    func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "GHelper"
            win.minSize = NSSize(width: 820, height: 560)
            win.contentViewController = NSHostingController(
                rootView: RootView(showWindowAction: nil).environmentObject(AppModel.shared))
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.collectionBehavior = [.managed, .fullScreenAuxiliary]
            win.setFrameAutosaveName("GHelperMainWindow") // 记住位置/大小，不再每次落到左下角
            win.center() // 首次打开居中于主屏幕
            mainWindow = win
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关窗只隐藏，不退出（保留菜单栏常驻）。
    /// ⚠️ 关键：把窗口 orderOut 后要让出前台——否则 .regular 策略下 App 没有窗口
    /// 却仍占着 frontmost，键盘事件全被它吞掉，用户打字打着打着就被截断。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        resignFrontIfNoVisibleWindow()
        return false
    }

    /// 没有可见窗口时主动退到后台（菜单栏图标不受影响）。
    /// 在关窗、启动完成、切回纯菜单栏模式时调用。
    func resignFrontIfNoVisibleWindow() {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
        guard !hasVisibleWindow else { return }
        NSApp.hide(nil)              // 让出 frontmost，键盘交还给正在输入的 App
    }

    @objc private func resignFrontOnNotification() {
        Task { @MainActor in self.resignFrontIfNoVisibleWindow() }
    }

    /// 点 Dock 图标 / 重新打开时显示窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        titleTimer?.invalidate()
    }
}
