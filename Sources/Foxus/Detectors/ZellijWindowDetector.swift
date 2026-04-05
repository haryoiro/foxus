import AppKit
import Foundation

/// zellij環境でウィンドウ・ペインを特定するユーティリティ
///
/// zellij は起動時に以下の環境変数を子プロセスに注入する:
/// - `ZELLIJ`              : セッションの存在フラグ（値は常に "0"）
/// - `ZELLIJ_SESSION_NAME` : セッション名
/// - `ZELLIJ_PANE_ID`      : ペインID（数値）
///
/// フォーカス復元は `zellij action focus-pane-with-id` コマンドで行う。
public enum ZellijWindowDetector {

    // MARK: - フォーカス復元

    /// 実ターミナルにフォーカスし、元のペインを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(zellij): cwd=\(cwd ?? "nil", privacy: .public)")

        // 実ターミナルアプリを特定してフォーカス
        if let bundleId = detectRealTerminalBundleId() {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = apps.first {
                if let cwd = cwd {
                    _ = WindowDetectorUtils.focusWindowInApp(app, matchingCwd: cwd)
                }
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        // ペインを復元
        restorePane()
        return true
    }

    // MARK: - Private

    /// プロセスツリーを辿って実ターミナルアプリのバンドルIDを検出
    private static func detectRealTerminalBundleId() -> String? {
        var currentPid = getpid()
        var visited: Set<pid_t> = []

        for _ in 0..<20 {
            guard !visited.contains(currentPid) else { break }
            visited.insert(currentPid)

            let parentPid = ProcessUtils.getParentPid(of: currentPid)
            guard parentPid > 1 else { break }

            if let bundleId = NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier == parentPid })?.bundleIdentifier {
                return bundleId
            }
            currentPid = parentPid
        }
        return nil
    }

    /// `zellij action focus-pane-with-id` でペインを復元
    private static func restorePane() {
        guard let paneId = ProcessInfo.processInfo.environment["ZELLIJ_PANE_ID"] else {
            Log.focus.debug("restorePane(zellij): ZELLIJ_PANE_ID 未設定")
            return
        }

        guard let zellijPath = ProcessUtils.findBinary("zellij", fallbacks: [
            "/opt/homebrew/bin/zellij",
            "/usr/local/bin/zellij"
        ]) else {
            Log.focus.warning("restorePane(zellij): zellij バイナリが見つかりません")
            return
        }

        Log.focus.debug("restorePane(zellij): paneId=\(paneId, privacy: .public)")
        _ = ProcessUtils.runCommand(zellijPath, arguments: [
            "action", "focus-pane-with-id", paneId
        ])
    }
}
