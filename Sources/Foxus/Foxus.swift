import AppKit
import Foundation

/// foxusのメインエントリーポイント
///
/// `FocusStrategy`を受け取り、適切なDetectorを呼び出してウィンドウにフォーカスする。
///
/// 使い方:
/// ```swift
/// // ワンライナー（戦略決定→実行まで全部やる）
/// let result = Foxus.focus(callerApp: "ghostty", cwd: "/path/to/project")
/// if !result.succeeded { /* 独自フォールバック */ }
///
/// // 戦略を自分で決めて実行
/// let strategy = FocusStrategyResolver.determine(callerApp: ..., cwd: ..., env: env)
/// Foxus.execute(strategy: strategy)
/// ```
public enum Foxus {

    /// 戦略を指定してフォーカスを実行
    ///
    /// - Parameter strategy: 採用するフォーカス戦略
    /// - Returns: フォーカスに成功した場合はtrue
    @discardableResult
    public static func execute(strategy: FocusStrategy) -> Bool {
        switch strategy {
        case .cmux(let cwd):
            return CmuxWindowDetector.focusCurrentWindow(cwd: cwd)
        case .tmux(let cwd):
            return TmuxWindowDetector.focusCurrentWindow(cwd: cwd)
        case .zellij(let cwd):
            return ZellijWindowDetector.focusCurrentWindow(cwd: cwd)
        case .wezterm(let cwd):
            return WeztermWindowDetector.focusCurrentWindow(cwd: cwd)
        case .kitty(let cwd):
            return KittyWindowDetector.focusCurrentWindow(cwd: cwd)
        case .vscode(let cwd):
            return VSCodeWindowDetector.focusCurrentWindow(cwd: cwd)
        case .intellij(let cwd):
            return IntelliJWindowDetector.focusCurrentWindow(cwd: cwd)
        case .generic(let bundleId, let cwd):
            return executeGeneric(bundleId: bundleId, cwd: cwd)
        case .fallback:
            // 呼び出し元でフォールバック処理を行う
            return false
        }
    }

    /// 環境情報から戦略を決定してフォーカスを実行
    ///
    /// `callerApp`・`cwd` ともに省略すると自動検出する。
    ///
    /// - Parameters:
    ///   - callerApp: 呼び出し元アプリ（省略時は自動検出）
    ///   - cwd: 作業ディレクトリ（省略時は自動検出）
    ///   - env: 環境変数辞書（デフォルト: ProcessInfo.processInfo.environment）
    /// - Returns: 採用された戦略と成否
    @discardableResult
    public static func focus(
        callerApp: String? = nil,
        cwd: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> FocusResult {
        let resolved = callerApp ?? ProcessDetector.detectTerminalApp(env: env)
        let resolvedCwd = cwd ?? ProcessUtils.getCwdFromCurrentTty() ?? ProcessUtils.getParentCwd()
        let strategy = FocusStrategyResolver.determine(callerApp: resolved, cwd: resolvedCwd, env: env)
        let succeeded = execute(strategy: strategy)
        return FocusResult(strategy: strategy, succeeded: succeeded)
    }

    // MARK: - Private

    /// .generic 戦略の実行
    ///
    /// 優先順位:
    /// 1. バンドルIDが分かっていれば、そのアプリ内でcwdマッチ
    /// 2. cwdマッチ失敗時はアプリ全体をアクティブ化
    /// 3. バンドルID未解決時はcwdのフォルダ名で全ターミナルアプリを検索
    private static func executeGeneric(bundleId: String?, cwd: String?) -> Bool {
        if let bundleId = bundleId {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let cwd = cwd {
                for app in apps where WindowFocus.focusWindowInApp(app, matchingCwd: cwd) {
                    return true
                }
            }
            // cwdマッチ失敗: アプリ全体をアクティブ化
            if let app = apps.first {
                app.activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }

        // バンドルID未解決: cwdのフォルダ名で全ターミナルアプリを検索
        if let cwd = cwd {
            let folderName = (cwd as NSString).lastPathComponent
            let allBundleIds = Array(BundleIDRegistry.terminalApps.keys)
            if !folderName.isEmpty,
               WindowFocus.focusWindowByTitle(folderName, bundleIds: allBundleIds) {
                return true
            }
        }

        return false
    }
}

// MARK: - FocusResult

/// `Foxus.focus(callerApp:cwd:env:)` の実行結果
public struct FocusResult {
    /// 採用された戦略
    public let strategy: FocusStrategy
    /// フォーカスに成功したかどうか
    public let succeeded: Bool
}
