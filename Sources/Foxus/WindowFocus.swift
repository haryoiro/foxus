import AppKit
import ApplicationServices
import Darwin
import Foundation

// MARK: - CGS プライベートAPI宣言
// macOSの非公開API。ウィンドウを別のSpace（仮想デスクトップ）に移動するために使用。
// 公開APIではSpace間のウィンドウ移動ができないため、これに頼っている。
// 将来のmacOSで動作しなくなる可能性がある。

// MARK: - 将来の改善候補
//
// [SkyLight SLS API について]
// yabai は SkyLight.framework のプライベートシンボル（SLSCopyWindowsWithOptionsAndTags など）を使い、
// 複数Space のウィンドウをバッチ取得している。現在の AX API（kAXWindowsAttribute）より大幅に速く、
// Accessibility権限も不要。
// ただし macOS メジャーアップデートでシンボル名が変わることがあり（yabai も毎バージョン修正が入る）、
// 常駐してウィンドウを大量管理するアプリ（notiro など）ができた時点で検討する。
// 参考: https://github.com/koekeishiya/yabai/blob/master/src/space.c
//
// [AXUIElement → CGWindowID キャッシュについて]
// 現在は focusWindowInApp() のたびに kAXWindowsAttribute でウィンドウを全列挙している。
// AXUIElement から _AXUIElementGetWindow で取得した CGWindowID をメモリ内辞書でキャッシュすれば
// 再列挙を省ける。ただし pyokotify は短命プロセスなので恩恵が薄い。
// notiro のような常駐アプリで複数回フォーカスが走る場合に有効。

private typealias CGSConnectionID = UInt32
private typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windows: CFArray, _ space: CGSSpaceID)

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindow: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AXUIElementを使ったウィンドウ操作ユーティリティ
///
/// Space移動・ウィンドウフォーカスなど、AppKit/AXに関わる操作を担う。
/// プロセス/システム操作は `ProcessUtils` を参照。
public enum WindowFocus {

    // MARK: - Space移動（CGSプライベートAPI）

    /// AXUIElementからCGWindowIDを取得
    private static func getWindowID(from axWindow: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(axWindow, &windowID)
        return result == .success ? windowID : nil
    }

    /// 指定ウィンドウを現在のSpaceに移動
    public static func moveWindowToCurrentSpace(_ windowID: CGWindowID) {
        let cid = CGSMainConnectionID()
        let currentSpace = CGSGetActiveSpace(cid)
        let windowArray = [windowID] as CFArray
        CGSMoveWindowsToManagedSpace(cid, windowArray, currentSpace)
    }

    /// AXUIElementのウィンドウを現在のSpaceに移動
    /// - Returns: 移動に成功した場合はtrue
    @discardableResult
    public static func moveWindowToCurrentSpace(_ axWindow: AXUIElement) -> Bool {
        guard let windowID = getWindowID(from: axWindow) else { return false }
        moveWindowToCurrentSpace(windowID)
        return true
    }

    // MARK: - ウィンドウタイトル取得

    /// アプリのフォーカスウィンドウ（なければメインウィンドウ）のタイトルを返す
    public static func windowTitle(for app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = axWindow(axApp, attribute: kAXFocusedWindowAttribute)
                  ?? axWindow(axApp, attribute: kAXMainWindowAttribute)
        guard let window else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success,
              let title = ref as? String, !title.isEmpty else { return nil }
        return title
    }

    private static func axWindow(_ axApp: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
              let element = ref,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        // CFTypeID already verified above; cast is safe for CoreFoundation types.
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    // MARK: - ウィンドウフォーカス

    /// cwdでフルパスマッチ → フォルダ名マッチの順でウィンドウをフォーカス
    ///
    /// 各Detectorで繰り返し現れる「まずcwd全体でマッチ、次にlastPathComponentで再試行」
    /// というパターンを一箇所に集約したもの。
    /// - Returns: どちらかのマッチでフォーカスできた場合はtrue
    @discardableResult
    public static func focusWindowInApp(_ app: NSRunningApplication, matchingCwd cwd: String) -> Bool {
        if focusWindowInApp(app, matchingTitle: cwd) { return true }
        let folderName = (cwd as NSString).lastPathComponent
        guard !folderName.isEmpty else { return false }
        return focusWindowInApp(app, matchingTitle: folderName)
    }

    /// アプリ内でタイトルにマッチするウィンドウをフォーカス
    /// - Returns: マッチしてフォーカスできた場合はtrue
    @discardableResult
    public static func focusWindowInApp(_ app: NSRunningApplication, matchingTitle titlePart: String) -> Bool {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        let appName = app.localizedName ?? "unknown"
        Log.focus.debug("focusWindowInApp: app=\(appName, privacy: .public), pid=\(pid), titlePart=\(titlePart, privacy: .public)")

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            Log.focus.warning("AXUIElementCopyAttributeValue 失敗: \(result.rawValue) (app=\(appName, privacy: .public))")
            return false
        }

        Log.focus.debug("  -> ウィンドウ数: \(windows.count) (app=\(appName, privacy: .public))")

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? "(no title)"
            Log.focus.debug("  -> ウィンドウタイトル: \(title, privacy: .public)")

            if title.contains(titlePart) {
                Log.focus.debug("  -> マッチ: \(title, privacy: .public) — フォーカス試行中")

                let moved = moveWindowToCurrentSpace(window)
                Log.focus.debug("  -> moveWindowToCurrentSpace: \(moved)")

                let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                switch raised {
                case .success:
                    Log.focus.debug("  -> AXRaiseAction: success")
                case .attributeUnsupported:
                    // このアプリはkAXRaiseActionを実装していない（Electron系など）
                    // activate()で代替されるため動作上は問題なし
                    Log.focus.debug("  -> AXRaiseAction: attributeUnsupported (スキップ)")
                default:
                    Log.focus.warning("  -> AXRaiseAction: \(raised.rawValue) (\(appName, privacy: .public))")
                }

                let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                Log.focus.debug("  -> activate: \(activated)")

                return true
            }
        }

        Log.focus.debug("  -> マッチするウィンドウが見つかりません (titlePart=\(titlePart, privacy: .public))")
        return false
    }

    /// 指定バンドルIDのアプリでタイトルマッチするウィンドウをフォーカス
    @discardableResult
    public static func focusWindowByTitle(_ titlePart: String, bundleIds: [String]) -> Bool {
        for bundleId in bundleIds {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            for app in apps where focusWindowInApp(app, matchingTitle: titlePart) {
                return true
            }
        }
        return false
    }

    /// 指定バンドルIDのいずれかのアプリにフォーカス
    @discardableResult
    public static func focusAnyApp(bundleIds: [String]) -> Bool {
        for bundleId in bundleIds {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = apps.first {
                app.activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }
        return false
    }
}
