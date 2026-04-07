import Foundation

/// 環境情報からフォーカス戦略を決定する（純粋関数）
///
/// `ProcessInfo.processInfo.environment` に依存しないため、
/// 任意の環境変数の組み合わせでテスト可能。
public enum FocusStrategyResolver {

    /// 環境情報からフォーカス戦略を決定
    /// - Parameters:
    ///   - callerApp: ProcessDetectorが検出したアプリ名（TERM_PROGRAM名またはバンドルID）
    ///   - cwd: 作業ディレクトリ
    ///   - env: 環境変数辞書
    /// - Returns: 採用すべきフォーカス戦略
    /// 環境情報からフォーカス戦略を決定
    ///
    /// callerApp が明示的にエディタを指定している場合はマルチプレクサより優先する。
    /// これにより、cmux 内から開いた VSCode で callerApp="vscode" を指定すれば
    /// VSCode のウィンドウにフォーカスできる。
    public static func determine(
        callerApp: String?,
        cwd: String?,
        env: [String: String]
    ) -> FocusStrategy {
        // callerApp が明示的にエディタを指している場合、最優先で評価
        if let caller = callerApp, !caller.isEmpty {
            if isVSCodeEnvironment(callerApp: caller, env: [:]) {
                return .vscode(cwd: cwd)
            }
            if isIntelliJEnvironment(callerApp: caller, env: [:]) {
                return .intellij(cwd: cwd)
            }
        }

        // 1. VSCode 統合ターミナル（VSCODE_GIT_IPC_HANDLE が明示的に VSCode 内を示す場合は cmux より優先）
        if isVSCodeEnvironment(callerApp: nil, env: env) {
            return .vscode(cwd: cwd)
        }

        // 2. Neovim :terminal（NVIM 環境変数で検出、マルチプレクサより先に判定）
        if env["NVIM"] != nil {
            return .neovim(cwd: cwd)
        }

        // 3. cmux（タブ復元が必要なため、tmuxより先に判定）
        if env["CMUX_WORKSPACE_ID"] != nil {
            return .cmux(cwd: cwd)
        }

        // 2. tmux
        if env["TMUX"] != nil {
            return .tmux(cwd: cwd)
        }

        // 3. zellij
        if env["ZELLIJ"] != nil {
            return .zellij(cwd: cwd)
        }

        // 4. WezTerm
        if env["WEZTERM_PANE"] != nil {
            return .wezterm(cwd: cwd)
        }

        // 5. kitty
        if env["KITTY_WINDOW_ID"] != nil {
            return .kitty(cwd: cwd)
        }

        // 6. Ghostty
        if env["TERM_PROGRAM"] == "ghostty" || env["GHOSTTY_RESOURCES_DIR"] != nil {
            return .ghostty(cwd: cwd)
        }

        // 7. IntelliJ（callerApp 未指定時のみ環境変数で検出）
        if callerApp == nil || callerApp?.isEmpty == true {
            if isIntelliJEnvironment(callerApp: nil, env: env) {
                return .intellij(cwd: cwd)
            }
        }

        // 7. 汎用（callerAppからバンドルIDを解決）
        let bundleId = resolveBundleId(callerApp)
        if bundleId != nil || cwd != nil {
            return .generic(bundleId: bundleId, cwd: cwd)
        }

        // 9. フォールバック
        return .fallback
    }

    // MARK: - Private

    private static func isVSCodeEnvironment(
        callerApp: String?,
        env: [String: String]
    ) -> Bool {
        if let caller = callerApp {
            let lower = caller.lowercased()
            if lower.contains("vscode") { return true }
            return false
        }

        if let termProgram = env["TERM_PROGRAM"] {
            if termProgram.lowercased().contains("vscode") { return true }
            return false
        }

        if env["VSCODE_GIT_IPC_HANDLE"] != nil {
            return true
        }

        return false
    }

    private static func isIntelliJEnvironment(
        callerApp: String?,
        env: [String: String]
    ) -> Bool {
        let jetBrainsNames = [
            "idea", "intellij", "appcode", "clion", "webstorm",
            "pycharm", "phpstorm", "goland", "rubymine", "rider",
            "datagrip", "fleet"
        ]

        if let caller = callerApp?.lowercased() {
            for name in jetBrainsNames where caller.contains(name) { return true }
            return false
        }

        if let bundleId = env["__CFBundleIdentifier"],
            bundleId.contains("jetbrains") {
            return true
        }

        if let termEmulator = env["TERMINAL_EMULATOR"],
            termEmulator.contains("JetBrains") {
            return true
        }

        if env["__INTELLIJ_COMMAND_HISTFILE__"] != nil {
            return true
        }

        return false
    }

    private static func resolveBundleId(_ callerApp: String?) -> String? {
        guard let caller = callerApp, !caller.isEmpty else { return nil }
        if let bundleId = BundleIDRegistry.termProgramToBundleId[caller] {
            return bundleId
        }
        if caller.contains(".") {
            return caller
        }
        return nil
    }
}
