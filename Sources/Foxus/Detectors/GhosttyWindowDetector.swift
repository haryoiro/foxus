import AppKit
import Foundation

/// Ghostty環境でウィンドウ・タブを特定するユーティリティ
///
/// Ghostty v1.3+ の AppleScript API を使用してタブ操作・タイトル取得を行う。
/// AX API やアクセシビリティ権限は不要。
///
/// 検出環境変数:
/// - `TERM_PROGRAM=ghostty`
/// - `GHOSTTY_RESOURCES_DIR`
public enum GhosttyWindowDetector {

    private static let bundleId = "com.mitchellh.ghostty"

    // MARK: - タイトル取得

    /// Ghostty で cwd にマッチするターミナルの名前を返す
    /// cwd が nil の場合はフロントウィンドウの選択タブ名を返す
    public static func windowTitle(cwd: String? = nil) -> String? {
        if let cwd = cwd {
            // cwd にマッチするターミナルの名前を取得
            let script = """
            tell application "Ghostty"
                set matches to every terminal whose working directory contains "\(escapeForAS(cwd))"
                if (count of matches) > 0 then
                    return name of item 1 of matches
                end if
            end tell
            """
            return runAppleScript(script)
        }

        // フォールバック: フロントウィンドウの選択タブ名
        let script = """
        tell application "Ghostty"
            if (count of windows) > 0 then
                return name of selected tab of front window
            end if
        end tell
        """
        return runAppleScript(script)
    }

    // MARK: - フォーカス復元

    /// Ghosttyにフォーカスし、cwdに一致するタブを復元
    public static func focusCurrentWindow(cwd: String?) -> Bool {
        Log.focus.debug("focusCurrentWindow(ghostty): cwd=\(cwd ?? "nil", privacy: .public)")

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            Log.focus.warning("focusCurrentWindow(ghostty): Ghosttyアプリが見つかりません")
            return false
        }

        // AppleScript でタブフォーカスを試行
        if let cwd = cwd, focusTerminalByCwd(cwd) {
            app.activate(options: [.activateIgnoringOtherApps])
            return true
        }

        // フォールバック: ウィンドウタイトルマッチ
        if let cwd = cwd {
            if WindowFocus.focusWindowInApp(app, matchingCwd: cwd) {
                return true
            }
        }

        // 最終フォールバック: アプリ全体をアクティブ化
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // MARK: - Private: AppleScript によるタブフォーカス

    /// cwd にマッチするターミナルにフォーカスする
    private static func focusTerminalByCwd(_ cwd: String) -> Bool {
        let script = """
        tell application "Ghostty"
            set matches to every terminal whose working directory contains "\(escapeForAS(cwd))"
            if (count of matches) > 0 then
                focus item 1 of matches
                return "ok"
            end if
            return "no match"
        end tell
        """
        let result = runAppleScript(script)
        Log.focus.debug("focusTerminalByCwd: result=\(result ?? "nil", privacy: .public)")
        return result == "ok"
    }

    // MARK: - Private: AppleScript 実行

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error = error {
            Log.focus.debug("AppleScript error: \(error, privacy: .public)")
            return nil
        }
        let str = result?.stringValue
        return (str?.isEmpty == false) ? str : nil
    }

    /// AppleScript 文字列リテラル用エスケープ
    static func escapeForAS(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if ch.asciiValue != nil && ch.asciiValue! < 0x20 {
                    // Other control characters: skip them to avoid breaking AppleScript
                    continue
                }
                result.append(ch)
            }
        }
        return result
    }
}
