//
//  UpdateChecker.swift — 检查更新 + 一键更新（对接 GitHub Releases）
//
//  对接仓库：Anoxia965/GHelper-macOS。以后更新只要往 GitHub 打 tag 发 Release、
//  附上 GHelper.dmg，App 里点「检查更新」→「下载并更新」就能：
//  检测新版 → 下载 DMG → 删掉旧安装（移到废纸篓）→ 装新版 → 重启。
//

import Foundation
import AppKit

// MARK: - GitHub Release 模型

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String?
    let publishedAt: String?
    let prerelease: Bool
    let draft: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case assets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName        = try c.decode(String.self, forKey: .tagName)
        name           = try c.decodeIfPresent(String.self, forKey: .name)
        body           = try c.decodeIfPresent(String.self, forKey: .body)
        htmlUrl        = try c.decodeIfPresent(String.self, forKey: .htmlUrl)
        publishedAt    = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        prerelease     = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        draft          = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        assets         = try c.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }

    /// 发布页地址
    var pageURL: URL? { htmlUrl.flatMap(URL.init(string:)) }

    /// 找某个附件的下载地址（按名字模糊匹配）
    func assetURL(_ keyword: String) -> URL? {
        guard let a = assets.first(where: { $0.name.lowercased().contains(keyword.lowercased()) }),
              let u = URL(string: a.browserDownloadUrl)
        else { return nil }
        return u
    }

    /// App 安装包（优先 DMG，退回 zip，最后发布页）
    var appDownloadURL: URL? {
        assetURL(".dmg") ?? assetURL("app.zip") ?? pageURL
    }
    /// 驱动包（Kexts.zip）
    var kextsDownloadURL: URL? { assetURL("kexts") }
}

struct GitHubAsset: Decodable {
    let id: Int
    let name: String
    let size: Int
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - 更新检查器

@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    enum State {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? = nil

    /// 新版本从这里来：往 GitHub 打 tag + Release、附 GHelper.dmg，这里就能检测到
    private nonisolated static let releasesAPI =
        "https://api.github.com/repos/Anoxia965/GHelper-macOS/releases/latest"
    nonisolated static let releasesPage =
        "https://github.com/Anoxia965/GHelper-macOS/releases"

    /// 当前版本：优先读 Info.plist 的 CFBundleShortVersionString
    nonisolated static var currentVersion: String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !s.isEmpty { return s }
        return "1.5.0"
    }

    /// 有待更新版本（给菜单栏角标 / 设置页用）
    var updateAvailable: GitHubRelease? {
        if case .available(let r) = state { return r }
        return nil
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    /// 检查更新。
    /// - Parameter auto: true 表示启动静默检查——失败不显示错误，只在发现新版时亮角标。
    func check(auto: Bool = false) {
        guard !isChecking else { return }
        state = .checking
        Task {
            do {
                let rel = try await Self.fetchLatest()
                lastChecked = Date()
                if Self.isUpdate(rel.tagName, than: Self.currentVersion) {
                    state = .available(rel)
                } else {
                    state = .upToDate
                }
            } catch {
                lastChecked = Date()
                state = auto ? .idle : .failed(Self.message(for: error))
            }
        }
    }

    // MARK: 网络

    nonisolated static func fetchLatest() async throws -> GitHubRelease {
        guard let url = URL(string: releasesAPI) else { throw UpdateError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GHelper-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: 版本比较

    /// "v1.2.3" / "1.2" 与本地版本逐段比较，remote 更新则 true
    nonisolated static func isUpdate(_ remote: String, than current: String) -> Bool {
        let r = components(remote), c = components(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    /// "v1.2.3-beta" → [1,2,3]
    nonisolated static func components(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let f = t.first, !f.isNumber { t.removeFirst() }
        return t.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if let e = error as? UpdateError { return e.description }
        return "检查失败：\(error.localizedDescription)"
    }
}

enum UpdateError: Error {
    case badURL
    case http(Int)

    var description: String {
        switch self {
        case .badURL: return "仓库地址无效"
        case .http(let code):
            switch code {
            case 404: return "GitHub 上还没有发布版本"
            case 403, 429: return "被 GitHub 限流，稍后再试"
            default:  return "GitHub 返回错误 \(code)"
            }
        }
    }
}

// MARK: - 一键更新（下载 → 删旧 → 装新 → 重启）

@MainActor
final class UpdateInstaller: ObservableObject {

    static let shared = UpdateInstaller()

    enum Phase {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }
    @Published private(set) var phase: Phase = .idle

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }
    var statusText: String {
        switch phase {
        case .idle:            return ""
        case .working(let s):  return s
        case .done(let s):     return s
        case .failed(let s):   return s
        }
    }

    /// 一键更新：检测到的 release → 下载 DMG → 删掉旧安装 → 装新版 → 重启
    func installUpdate(_ release: GitHubRelease, relaunch: Bool = true) {
        guard !isWorking else { return }
        phase = .working("正在下载 \(release.tagName)…")

        Task {
            do {
                guard let remote = release.appDownloadURL else { throw InstallError.noPackage }
                let isDMG = remote.pathExtension.lowercased() == "dmg"

                // 1) 下载
                let (data, resp) = try await URLSession.shared.data(from: remote)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw InstallError.http(http.statusCode)
                }
                let pkg = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GHelper-pkg-\(UUID().uuidString).\(isDMG ? "dmg" : "zip")")
                try data.write(to: pkg)

                // 2) 解开 → 找到 GHelper.app
                phase = .working("正在解包…")
                var sourceApp: URL
                var tempDirs: [URL] = []
                if isDMG {
                    let mnt = try Self.mountDMG(pkg)
                    tempDirs.append(mnt)
                    guard let a = Self.findApp(in: mnt) else { throw InstallError.noBundle }
                    sourceApp = a
                } else {
                    let work = FileManager.default.temporaryDirectory
                        .appendingPathComponent("GHelper-work-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    tempDirs.append(work)
                    try Self.unzip(pkg, to: work)
                    guard let a = Self.findApp(in: work) else { throw InstallError.noBundle }
                    sourceApp = a
                }

                // 3) 删掉旧安装（移到废纸篓）→ 装新版
                phase = .working("正在替换旧版本…")
                let target = Self.installTarget
                try Self.replaceInstall(at: target, with: sourceApp)

                // 4) 清理临时文件
                for d in tempDirs { Self.unmountOrRemove(d) }
                try? FileManager.default.removeItem(at: pkg)

                phase = .done("已更新到 \(release.tagName)。旧安装已移到废纸篓。请点「安装/重装」更新助手。")

                if relaunch {
                    phase = .done("已更新到 \(release.tagName)，正在重启…")
                    NSWorkspace.shared.openApplication(
                        at: target,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, _ in
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }
            } catch {
                phase = .failed(Self.text(for: error))
            }
        }
    }

    /// 当前 App 应被替换到的位置（同名同目录）
    nonisolated static var installTarget: URL {
        let cur = URL(fileURLWithPath: Bundle.main.bundlePath)
        return cur.deletingLastPathComponent().appendingPathComponent("GHelper.app")
    }

    /// 把旧安装移到废纸篓（等价“自动删除旧安装”，可恢复），再把新 App 拷进去
    nonisolated static func replaceInstall(at target: URL, with newApp: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // ① 删除旧安装：移到废纸篓
        if fm.fileExists(atPath: target.path) {
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        // ② 装新
        try fm.copyItem(at: newApp, to: target)
        // ③ 去掉隔离属性，避免 Gatekeeper 拦截
        stripQuarantine(at: target)
    }

    /// 在解开的目录里找 GHelper.app（含一层子目录）
    nonisolated static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        if let a = items.first(where: { $0.pathExtension == "app" && $0.lastPathComponent.contains("GHelper") }) {
            return a
        }
        for it in items {
            if let sub = try? fm.contentsOfDirectory(at: it, includingPropertiesForKeys: nil),
               let a = sub.first(where: { $0.pathExtension == "app" && $0.lastPathComponent.contains("GHelper") }) {
                return a
            }
        }
        return items.first { $0.pathExtension == "app" }
    }

    // MARK: 磁盘 / 进程工具

    nonisolated static func mountDMG(_ dmg: URL) throws -> URL {
        let mnt = FileManager.default.temporaryDirectory
            .appendingPathComponent("GHelper-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mnt.path, dmg.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            throw InstallError.mountFailed(String(data: d, encoding: .utf8) ?? "hdiutil")
        }
        return mnt
    }

    nonisolated static func unmountOrRemove(_ url: URL) {
        // 是挂载点就 detach，普通目录就删
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["detach", url.path, "-force", "-quiet"]
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func unzip(_ zip: URL, to dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw InstallError.unzipFailed }
    }

    nonisolated static func stripQuarantine(at url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? p.run(); p.waitUntilExit()
    }

    nonisolated static func text(for error: Error) -> String {
        if let e = error as? InstallError { return e.description }
        return "更新失败：\(error.localizedDescription)"
    }
}

enum InstallError: Error {
    case noPackage
    case noBundle
    case http(Int)
    case mountFailed(String)
    case unzipFailed

    var description: String {
        switch self {
        case .noPackage:        return "没找到安装包下载地址"
        case .noBundle:         return "安装包里没找到 GHelper.app"
        case .http(let c):      return "下载失败（HTTP \(c)）"
        case .mountFailed(let m): return "挂载 DMG 失败：\(m.prefix(120))"
        case .unzipFailed:      return "解压失败"
        }
    }
}
