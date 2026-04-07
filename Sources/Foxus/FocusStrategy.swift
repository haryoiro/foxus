import Foundation

/// 通知クリック時にどの検出パスを取るかを表す
///
/// GUI操作から切り離された純粋なデータ型。
/// 「どのDetectorを使うか」の判定ロジックだけをテスト可能にする。
public enum FocusStrategy: Equatable, Codable {
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
    /// Neovim :terminal 環境: 外側ターミナルにフォーカス + タブ復元
    case neovim(cwd: String?)
    /// VSCode: 専用ウィンドウ検出
    case vscode(cwd: String?)
    /// IntelliJ/JetBrains: 専用ウィンドウ検出
    case intellij(cwd: String?)
    /// 汎用: cwdベースのウィンドウマッチング
    case generic(bundleId: String?, cwd: String?)
    /// 最終フォールバック: frontmostApplicationに戻す
    case fallback
}

extension FocusStrategy {
    /// この戦略の復元に必要な環境変数キー。
    /// Detector ごとに異なる。新しい Detector を追加したらここにも追加する。
    public var restoreKeys: Set<String> {
        var keys: Set<String> = ["TERM_PROGRAM", "__CFBundleIdentifier"]
        switch self {
        case .cmux:
            keys.formUnion(["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH"])
        case .tmux:
            keys.formUnion(["TMUX", "TMUX_PANE"])
        case .zellij:
            keys.formUnion(["ZELLIJ", "ZELLIJ_PANE_ID"])
        case .wezterm:
            keys.formUnion(["WEZTERM_PANE", "WEZTERM_UNIX_SOCKET"])
        case .kitty:
            keys.formUnion(["KITTY_WINDOW_ID"])
        case .neovim:
            keys.formUnion([
                "NVIM",
                "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH",
                "TMUX", "TMUX_PANE",
                "ZELLIJ", "ZELLIJ_PANE_ID",
                "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET",
                "KITTY_WINDOW_ID",
            ])
        case .vscode:
            keys.formUnion(["VSCODE_GIT_IPC_HANDLE"])
        case .intellij:
            keys.formUnion(["TERMINAL_EMULATOR", "__INTELLIJ_COMMAND_HISTFILE__"])
        case .generic, .fallback:
            break
        }
        return keys
    }
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
