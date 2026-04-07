import AppKit
import Foundation

/// WezTerm環境でウィンドウ・ペインを特定するユーティリティ
///
/// WezTerm は起動時に以下の環境変数を子プロセスに注入する:
/// - `WEZTERM_PANE`        : ペインID（数値）
/// - `WEZTERM_UNIX_SOCKET` : JSON-RPCソケットパス
///
/// フォーカス復元は `wezterm cli focus-pane --pane-id` コマンドで行う。
/// （Unix socketに直接JSON-RPCを送ることも可能だが、CLIの方が安定している）
public enum WeztermWindowDetector: FocusDetector {

    /// FocusDetector プロトコル準拠: env は無視して cwd のみ使用
    public static func focusCurrentWindow(cwd: String?, env: [String: String]) -> Bool {
        focusCurrentWindow(cwd: cwd)
    }


    // MARK: - フォーカス復元

    /// WezTermにフォーカスし、元のペインを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(wezterm): cwd=\(cwd ?? "nil", privacy: .public)")
        return WindowFocus.focusTerminalApp(
            bundleId: "com.github.wez.wezterm",
            cwd: cwd,
            afterFocus: { restorePane() }
        )
    }

    // MARK: - Private

    /// `wezterm cli focus-pane` でペインを復元
    private static func restorePane() {
        let env = ProcessInfo.processInfo.environment
        guard let paneId = env["WEZTERM_PANE"] else {
            Log.focus.debug("restorePane(wezterm): WEZTERM_PANE 未設定")
            return
        }

        guard let weztermPath = BinaryPaths.wezterm() else {
            Log.focus.warning("restorePane(wezterm): wezterm バイナリが見つかりません")
            return
        }

        // ソケットパスが分かっていれば指定する（複数のWeztermサーバーが立ち上がっている場合に有効）
        var args = ["cli", "focus-pane", "--pane-id", paneId]
        if let socketPath = env["WEZTERM_UNIX_SOCKET"] {
            args = ["--unix-socket", socketPath] + args
        }

        Log.focus.debug("restorePane(wezterm): paneId=\(paneId, privacy: .public)")
        _ = ProcessUtils.runCommand(weztermPath, arguments: args)
    }
}
