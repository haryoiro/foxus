import Foundation

/// 通知クリック時にどの検出パスを取るかを表す
///
/// GUI操作から切り離された純粋なデータ型。
/// 「どのDetectorを使うか」の判定ロジックだけをテスト可能にする。
public enum FocusStrategy: Equatable {
    /// cmux環境: cmuxアプリにフォーカス + タブ（Surface）復元
    case cmux(cwd: String?)
    /// tmux環境: 実ターミナルにフォーカス + ペイン復元
    case tmux(cwd: String?)
    /// zellij環境: 実ターミナルにフォーカス + ペイン復元
    case zellij(cwd: String?)
    /// WezTerm環境: アプリにフォーカス + ペイン復元（Unix socket経由）
    case wezterm(cwd: String?)
    /// kitty環境: アプリにフォーカス + ウィンドウ復元（kitten @ 経由）
    case kitty(cwd: String?)
    /// VSCode: 専用ウィンドウ検出
    case vscode(cwd: String?)
    /// IntelliJ/JetBrains: 専用ウィンドウ検出
    case intellij(cwd: String?)
    /// 汎用: cwdベースのウィンドウマッチング
    case generic(bundleId: String?, cwd: String?)
    /// 最終フォールバック: frontmostApplicationに戻す
    case fallback
}

/// フォーカス失敗の原因
public enum FocusError: Error, Equatable {
    /// アプリが起動していない
    case appNotRunning(strategy: FocusStrategy)
    /// ウィンドウが見つからない（アプリは起動しているがcwdに一致するウィンドウがない）
    case windowNotFound(strategy: FocusStrategy)
    /// 戦略を決定できなかった（callerApp/cwd/環境変数すべて不明）
    case noStrategyAvailable
    /// Detector がフォーカスに失敗した（原因不明）
    case focusFailed(strategy: FocusStrategy)
}
