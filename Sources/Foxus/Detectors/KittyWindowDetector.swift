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
public enum KittyWindowDetector: FocusDetector {

    /// FocusDetector プロトコル準拠: env は無視して cwd のみ使用
    public static func focusCurrentWindow(cwd: String?, env: [String: String]) -> Bool {
        focusCurrentWindow(cwd: cwd)
    }


    // MARK: - フォーカス復元

    /// kittyにフォーカスし、元のウィンドウを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(kitty): cwd=\(cwd ?? "nil", privacy: .public)")
        return WindowFocus.focusTerminalApp(
            bundleId: "net.kovidgoyal.kitty",
            cwd: cwd,
            afterFocus: { restoreWindow() }
        )
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

        guard let kittyPath = BinaryPaths.kitty() else {
            Log.focus.warning("restoreWindow(kitty): kitten バイナリが見つかりません")
            return
        }

        Log.focus.debug("restoreWindow(kitty): windowId=\(windowId, privacy: .public)")
        _ = ProcessUtils.runCommand(kittyPath, arguments: [
            "@", "focus-window", "--match", "id:\(windowId)"
        ])
    }
}
