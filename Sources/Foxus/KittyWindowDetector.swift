import AppKit
import Foundation

/// kitty環境でウィンドウ・タブを特定するユーティリティ
///
/// kitty は起動時に以下の環境変数を子プロセスに注入する:
/// - `KITTY_WINDOW_ID` : ウィンドウID（数値）
/// - `KITTY_PID`       : kittyプロセスのPID
///
/// フォーカス復元は `kitten @ focus-window --match id:<ID>` コマンドで行う。
/// これには kitty.conf で `allow_remote_control yes` の設定が必要。
///
/// 設定例 (~/.config/kitty/kitty.conf):
///   allow_remote_control yes
public enum KittyWindowDetector {

    // MARK: - フォーカス復元

    /// kittyにフォーカスし、元のウィンドウを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(kitty): cwd=\(cwd ?? "nil", privacy: .public)")

        // kittyアプリにフォーカス
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "net.kovidgoyal.kitty")
        if let app = apps.first {
            if let cwd = cwd {
                _ = WindowDetectorUtils.focusWindowInApp(app, matchingCwd: cwd)
            }
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            Log.focus.warning("focusCurrentWindow(kitty): kittyアプリが見つかりません")
            return false
        }

        // ウィンドウを復元
        restoreWindow()
        return true
    }

    // MARK: - Private

    /// `kitten @ focus-window` でウィンドウを復元
    ///
    /// - Note: kitty.conf に `allow_remote_control yes` が必要
    private static func restoreWindow() {
        guard let windowId = ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"] else {
            Log.focus.debug("restoreWindow(kitty): KITTY_WINDOW_ID 未設定")
            return
        }

        guard let kittyPath = ProcessUtils.findBinary("kitten", fallbacks: [
            "/opt/homebrew/bin/kitten",
            "/usr/local/bin/kitten",
            "/Applications/kitty.app/Contents/MacOS/kitten"
        ]) else {
            Log.focus.warning("restoreWindow(kitty): kitten バイナリが見つかりません")
            return
        }

        Log.focus.debug("restoreWindow(kitty): windowId=\(windowId, privacy: .public)")
        _ = ProcessUtils.runCommand(kittyPath, arguments: [
            "@", "focus-window", "--match", "id:\(windowId)"
        ])
    }
}
