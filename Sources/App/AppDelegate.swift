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

        // 弹出面板（菜单栏快速视图）：传入「展开到窗口」回调
        let popoverView = RootView(showWindowAction: { [weak self] in self?.showMainWindow() })
            .environmentObject(model)
        let hosting = NSHostingController(rootView: popoverView)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.toolTip = "GHelper"
            updateTitle(model.menuBarTitle)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 1.5s 刷新一次状态栏温度
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateTitle(model.menuBarTitle)
            }
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
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "GHelper"
            win.minSize = NSSize(width: 640, height: 480)
            win.contentViewController = NSHostingController(
                rootView: RootView(showWindowAction: nil).environmentObject(AppModel.shared))
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.collectionBehavior = [.managed, .fullScreenAuxiliary]
            mainWindow = win
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关窗只隐藏，不退出（保留菜单栏常驻）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
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
