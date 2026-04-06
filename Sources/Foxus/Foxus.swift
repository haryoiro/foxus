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
    /// - Parameters:
    ///   - strategy: 採用するフォーカス戦略
    ///   - env: 使用する環境変数（デフォルト: 現在のプロセス環境）
    /// - Returns: フォーカスに成功した場合はtrue
    @discardableResult
    public static func execute(
        strategy: FocusStrategy,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch strategy {
        case .cmux(let cwd):
            return CmuxWindowDetector.focusCurrentWindow(cwd: cwd, env: env)
        case .tmux(let cwd):
            return TmuxWindowDetector.focusCurrentWindow(cwd: cwd)
        case .zellij(let cwd):
            return ZellijWindowDetector.focusCurrentWindow(cwd: cwd)
        case .wezterm(let cwd):
            return WeztermWindowDetector.focusCurrentWindow(cwd: cwd)
        case .kitty(let cwd):
            return KittyWindowDetector.focusCurrentWindow(cwd: cwd)
        case .vscode(let cwd):
            return VSCodeWindowDetector.focusCurrentWindow(cwd: cwd, env: env)
        case .intellij(let cwd):
            return IntelliJWindowDetector.focusCurrentWindow(cwd: cwd)
        case .generic(let bundleId, let cwd):
            return executeGeneric(bundleId: bundleId, cwd: cwd)
        case .fallback:
            return false
        }
    }

    /// フォーカスせずに戦略と復元用コンテキストだけ返す。
    ///
    /// hook から呼ばれた時点のプロセスコンテキスト（環境変数・プロセスツリー）で
    /// 戦略を決定し、後から `execute(context:)` で復元できる情報を返す。
    public static func resolve(
        callerApp: String? = nil,
        cwd: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedContext {
        let resolvedCaller = callerApp ?? ProcessDetector.detectTerminalApp(env: env)
        let resolvedCwd = cwd ?? ProcessUtils.getCwdFromCurrentTty() ?? ProcessUtils.getParentCwd()
        let strategy = FocusStrategyResolver.determine(callerApp: resolvedCaller, cwd: resolvedCwd, env: env)

        // 戦略に応じた復元用環境変数を抽出
        let restoreEnv = env.filter { strategy.restoreKeys.contains($0.key) }

        return ResolvedContext(
            strategy: strategy,
            callerApp: resolvedCaller,
            cwd: resolvedCwd,
            env: restoreEnv
        )
    }

    /// 保存済みコンテキストからフォーカスを実行する。
    ///
    /// `resolve()` で取得したコンテキストを保存しておき、
    /// 後から（別プロセスからでも）復元してフォーカスできる。
    @discardableResult
    public static func execute(context: ResolvedContext) -> FocusResult {
        // コンテキストの env を使って戦略を再決定
        // （戦略に紐づく環境変数が保存されているため正しく復元できる）
        let strategy = FocusStrategyResolver.determine(
            callerApp: context.callerApp,
            cwd: context.cwd,
            env: context.env
        )

        if case .fallback = strategy {
            return FocusResult(strategy: strategy, succeeded: false, error: .noStrategyAvailable)
        }

        let succeeded = execute(strategy: strategy, env: context.env)
        let error: FocusError? = succeeded ? nil : .focusFailed(strategy: strategy)
        return FocusResult(strategy: strategy, succeeded: succeeded, error: error)
    }

    /// 環境情報から戦略を決定してフォーカスを実行
    @discardableResult
    public static func focus(
        callerApp: String? = nil,
        cwd: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> FocusResult {
        let context = resolve(callerApp: callerApp, cwd: cwd, env: env)
        return execute(context: context)
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

// MARK: - ResolvedContext

/// `resolve()` が返す、フォーカス復元に必要な全情報。
/// `Codable` なので JSON で保存・復元できる。
public struct ResolvedContext: Codable {
    /// 決定された戦略
    public let strategy: FocusStrategy
    /// 検出された呼び出し元アプリ
    public let callerApp: String?
    /// 作業ディレクトリ
    public let cwd: String?
    /// 復元に必要な環境変数のスナップショット
    public let env: [String: String]
    public init(strategy: FocusStrategy, callerApp: String?, cwd: String?, env: [String: String]) {
        self.strategy = strategy
        self.callerApp = callerApp
        self.cwd = cwd
        self.env = env
    }
}

// MARK: - FocusResult

/// `Foxus.focus(callerApp:cwd:env:)` の実行結果
public struct FocusResult {
    /// 採用された戦略
    public let strategy: FocusStrategy
    /// フォーカスに成功したかどうか
    public let succeeded: Bool
    /// 失敗時のエラー原因（成功時はnil）
    public let error: FocusError?

    public init(strategy: FocusStrategy, succeeded: Bool, error: FocusError? = nil) {
        self.strategy = strategy
        self.succeeded = succeeded
        self.error = error
    }
}
