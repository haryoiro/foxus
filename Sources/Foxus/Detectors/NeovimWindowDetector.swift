import AppKit
import Foundation

/// Neovim :terminal 環境でウィンドウ + タブを復元するディテクター
///
/// Claude Code が Neovim の `:terminal` から起動された場合に、
/// 1. 外側のターミナル/マルチプレクサにフォーカスを委譲
/// 2. `nvim --server` 経由で cwd にマッチする Neovim タブを復元
///
/// **検出条件**: `NVIM` 環境変数が設定されている
///
/// **環境変数**:
/// - `NVIM`: Neovim の RPC ソケットパス（`:terminal` 内で自動設定）
public enum NeovimWindowDetector {

    // MARK: - Public

    /// Neovim 環境でウィンドウを特定してフォーカス
    /// - Parameters:
    ///   - cwd: 作業ディレクトリ
    ///   - env: 復元用環境変数
    /// - Returns: フォーカスに成功した場合は true
    public static func focusCurrentWindow(cwd: String?, env: [String: String]) -> Bool {
        Log.focus.debug("focusCurrentWindow(neovim): cwd=\(cwd ?? "nil", privacy: .public)")

        // Step 1: 外側のターミナル/マルチプレクサにフォーカスを委譲
        let termFocused = focusInnerTerminal(cwd: cwd, env: env)

        // Step 2: Neovim タブを復元
        if let nvimAddr = env["NVIM"], let cwd = cwd {
            restoreNeovimTab(serverAddr: nvimAddr, cwd: cwd)
        }

        return termFocused
    }

    // MARK: - Private: nvim バイナリ

    private static var nvimPath: String? {
        ProcessUtils.findBinary("nvim", fallbacks: [
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/usr/bin/nvim",
        ])
    }

    // MARK: - Private: ターミナルフォーカス委譲

    /// 外側のターミナル/マルチプレクサにフォーカスを委譲する。
    ///
    /// 保存済み env から内部のマルチプレクサを判定し、該当ディテクターに委譲する。
    @discardableResult
    private static func focusInnerTerminal(cwd: String?, env: [String: String]) -> Bool {
        if env["CMUX_WORKSPACE_ID"] != nil {
            return CmuxWindowDetector.focusCurrentWindow(cwd: cwd, env: env)
        }
        if env["TMUX"] != nil {
            return TmuxWindowDetector.focusCurrentWindow(cwd: cwd)
        }
        if env["ZELLIJ"] != nil {
            return ZellijWindowDetector.focusCurrentWindow(cwd: cwd)
        }
        if env["WEZTERM_PANE"] != nil {
            return WeztermWindowDetector.focusCurrentWindow(cwd: cwd)
        }
        if env["KITTY_WINDOW_ID"] != nil {
            return KittyWindowDetector.focusCurrentWindow(cwd: cwd)
        }

        // フォールバック: cwd のフォルダ名で全ターミナルアプリを検索
        if let cwd = cwd {
            let folderName = (cwd as NSString).lastPathComponent
            let allBundleIds = Array(BundleIDRegistry.terminalApps.keys)
            if !folderName.isEmpty,
               WindowFocus.focusWindowByTitle(folderName, bundleIds: allBundleIds) {
                return true
            }
        }

        return WindowFocus.focusAnyApp(bundleIds: Array(BundleIDRegistry.terminalApps.keys))
    }

    // MARK: - Private: Neovim タブ復元

    /// `nvim --server` 経由で cwd にマッチするタブに切り替える。
    ///
    /// 各タブページの `getcwd(-1, tabNr)` を確認し、
    /// cwd と一致（またはサブディレクトリ）するタブに切り替える。
    private static func restoreNeovimTab(serverAddr: String, cwd: String) {
        guard let nvim = nvimPath else {
            Log.focus.warning("restoreNeovimTab: nvim バイナリが見つかりません")
            return
        }

        Log.focus.debug("restoreNeovimTab: server=\(serverAddr, privacy: .public) cwd=\(cwd, privacy: .public)")

        // タブ数を取得
        guard let countStr = ProcessUtils.runCommand(nvim, arguments: [
            "--server", serverAddr,
            "--remote-expr", "tabpagenr('$')",
        ])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let tabCount = Int(countStr) else {
            Log.focus.debug("  -> タブ数取得失敗")
            return
        }

        // タブが 1 つなら切り替え不要
        guard tabCount > 1 else {
            Log.focus.debug("  -> タブ 1 つのみ、スキップ")
            return
        }

        Log.focus.debug("  -> タブ数: \(tabCount)")

        let normalizedCwd = (cwd as NSString).standardizingPath

        // 各タブの cwd を確認してマッチするものを探す
        for tabNr in 1...tabCount {
            guard let tabCwd = ProcessUtils.runCommand(nvim, arguments: [
                "--server", serverAddr,
                "--remote-expr", "getcwd(-1, \(tabNr))",
            ])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tabCwd.isEmpty else { continue }

            let normalizedTabCwd = (tabCwd as NSString).standardizingPath

            if normalizedTabCwd == normalizedCwd
                || normalizedCwd.hasPrefix(normalizedTabCwd + "/") {
                Log.focus.debug("  -> タブ \(tabNr) にマッチ: \(tabCwd, privacy: .public)")
                // ノーマルモードに戻してからタブを切り替え
                _ = ProcessUtils.runCommand(nvim, arguments: [
                    "--server", serverAddr,
                    "--remote-send", "<C-\\><C-n>:\(tabNr)tabnext<CR>",
                ])
                return
            }
        }

        Log.focus.debug("  -> マッチするタブなし")
    }
}
