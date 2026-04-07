import AppKit
import ApplicationServices
import Foundation

/// Ghostty環境でウィンドウ・タブを特定するユーティリティ
///
/// Ghostty は環境変数でタブIDを公開しないため、
/// Accessibility API でタブグループを探索し、タイトルマッチで切り替える。
///
/// 検出環境変数:
/// - `TERM_PROGRAM=ghostty`
/// - `GHOSTTY_RESOURCES_DIR`
public enum GhosttyWindowDetector {

    private static let bundleId = "com.mitchellh.ghostty"

    // MARK: - フォーカス復元

    /// Ghosttyにフォーカスし、cwdに一致するタブを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(ghostty): cwd=\(cwd ?? "nil", privacy: .public)")

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            Log.focus.warning("focusCurrentWindow(ghostty): Ghosttyアプリが見つかりません")
            return false
        }

        // タブ切替を試行
        if let cwd = cwd {
            let folderName = (cwd as NSString).lastPathComponent
            if selectTab(app: app, matching: cwd) || selectTab(app: app, matching: folderName) {
                app.activate(options: [.activateIgnoringOtherApps])
                return true
            }
            // タブが見つからなくてもウィンドウマッチにフォールバック
            if WindowFocus.focusWindowInApp(app, matchingCwd: cwd) {
                return true
            }
        }

        // 最終フォールバック: アプリ全体をアクティブ化
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // MARK: - AX API によるタブ切替

    /// AX API でタイトルにマッチするタブを選択
    private static func selectTab(app: NSRunningApplication, matching titlePart: String) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows {
            // macOS ネイティブタブ: AXTabs 属性
            if let tabs = axChildren(of: window, role: "AXTabGroup"),
               selectFromTabs(tabs, matching: titlePart) {
                // タブを持つウィンドウを前面に
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }

            // フォールバック: ウィンドウ直下の全子要素を再帰探索
            if selectTabRecursive(element: window, matching: titlePart) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }
        }

        return false
    }

    /// タブグループ内のタブからタイトルマッチするものを選択
    private static func selectFromTabs(_ tabs: [AXUIElement], matching titlePart: String) -> Bool {
        for tab in tabs {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""

            Log.focus.debug("  ghostty tab: \(title, privacy: .public)")

            if title.contains(titlePart) {
                Log.focus.debug("  -> マッチ: \(title, privacy: .public)")
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                return true
            }
        }
        return false
    }

    /// AX ツリーを再帰的に探索してタブを見つける
    private static func selectTabRecursive(element: AXUIElement, matching titlePart: String, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            // タブボタン / ラジオボタン（タブバーに使われることがある）
            if role == "AXTab" || role == "AXRadioButton" || role == "AXButton" {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""

                if !title.isEmpty {
                    Log.focus.debug("  ghostty ax[\(depth)]: role=\(role, privacy: .public) title=\(title, privacy: .public)")
                    if title.contains(titlePart) {
                        AXUIElementPerformAction(child, kAXPressAction as CFString)
                        return true
                    }
                }
            }

            // タブグループ内を再帰
            if role == "AXTabGroup" || role == "AXRadioGroup" || role == "AXGroup" || role == "AXToolbar" {
                if selectTabRecursive(element: child, matching: titlePart, depth: depth + 1) {
                    return true
                }
            }
        }

        return false
    }

    /// 指定ロールの子要素を取得
    private static func axChildren(of element: AXUIElement, role targetRole: String) -> [AXUIElement]? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == targetRole {
                // タブグループの子要素（= 個別タブ）を返す
                var tabsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabsRef) == .success,
                   let tabs = tabsRef as? [AXUIElement] {
                    return tabs
                }
                // AXTabs がなければ AXChildren を返す
                var innerRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &innerRef) == .success,
                   let inner = innerRef as? [AXUIElement] {
                    return inner
                }
            }
        }

        return nil
    }
}
