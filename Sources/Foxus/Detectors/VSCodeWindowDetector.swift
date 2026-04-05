import AppKit
import ApplicationServices
import Foundation

/// VSCode / Cursor / VSCodium のウィンドウを特定してフォーカスするユーティリティ。
///
/// 以下の優先順位で検出を試みる:
/// 1. VSCode メイン IPC ソケット経由で folderURIs を取得 → 完全パスマッチ（最も確実・タイトル不依存）
/// 2. `VSCODE_GIT_IPC_HANDLE` → Plugin PWD → プロジェクト名マッチ
/// 3. cwd のフォルダ名マッチ（cwdが提供されている場合）
/// 4. worktree の親リポジトリ名マッチ（cwd が `.worktrees/` を含む場合）
/// 5. TTY からウィンドウタイトルを推測
/// 6. フォールバック: VSCode アプリ全体をアクティブ化
public enum VSCodeWindowDetector {

    private static var bundleIds: [String] { BundleIDRegistry.vscodeBundleIds }

    /// VSCode ウィンドウを特定してフォーカスする。
    /// - Parameter cwd: hooks JSON から渡される作業ディレクトリ
    /// - Returns: 正しいウィンドウへのフォーカスに成功した場合は `true`
    public static func focusCurrentWindow(cwd: String? = nil) -> Bool {
        // 方法1: VSCode IPC ソケット経由でウィンドウを特定（タイトルマッチ不要）
        // folderURIs.path が cwd と完全一致するウィンドウを探す
        if let cwd = cwd, focusViaIPC(targetPath: cwd) {
            return true
        }

        // 方法2: VSCODE_GIT_IPC_HANDLE からウィンドウを特定
        // ソケット保持プロセスの PWD = そのウィンドウのワークスペースパス
        if let pluginPwd = detectPluginPwdFromIpcHandle() {
            let projectName = (pluginPwd as NSString).lastPathComponent
            if !projectName.isEmpty,
               WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                return true
            }
        }

        // 方法3: cwd のフォルダ名でウィンドウタイトルをマッチ
        if let cwd = cwd {
            let projectName = (cwd as NSString).lastPathComponent
            if !projectName.isEmpty,
               WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                return true
            }
        }

        // 方法4: git worktree 内の場合、親リポジトリ名でマッチ
        // 例: /path/to/myrepo/.worktrees/feature/branch → "myrepo" でウィンドウを検索
        if let cwd = cwd, let parentRepoName = extractWorktreeParentName(from: cwd) {
            if WindowFocus.focusWindowByTitle(parentRepoName, bundleIds: bundleIds) {
                return true
            }
        }

        // 方法5: TTY からシェルの cwd を取得してウィンドウタイトルを推測
        if let windowTitle = ProcessUtils.detectWindowTitleFromTty(),
           WindowFocus.focusWindowByTitle(windowTitle, bundleIds: bundleIds) {
            return true
        }

        // 方法6: フォールバック — ウィンドウ特定を諦め、アプリ全体をアクティブ化
        return WindowFocus.focusAnyApp(bundleIds: bundleIds)
    }

    // MARK: - IPC ソケット経由フォーカス

    /// VSCode メイン IPC ソケット経由でウィンドウをフォーカスする。
    ///
    /// `diagnostics.getMainDiagnostics()` で folderURIs を取得し、
    /// targetPath に完全一致するウィンドウがあれば `launch.start()` でフォーカスする。
    /// `launch.start()` は VSCode 内部で `app.focus({steal: true})` を呼ぶため、
    /// 別のSpaceにあるウィンドウも現在のSpaceに移動してフォーカスされる。
    ///
    /// - Parameter targetPath: フォーカスしたいワークスペースの絶対パス
    /// - Returns: 該当ウィンドウが見つかりフォーカスに成功した場合は true
    private static func focusViaIPC(targetPath: String) -> Bool {
        let socketPaths = VSCodeIPCClient.findSocketPaths()
        Log.focus.debug("VSCodeIPC: found \(socketPaths.count) socket(s)")

        for entry in socketPaths {
            Log.focus.debug("VSCodeIPC: trying \(entry.socketPath, privacy: .public)")

            guard let diagnostics = VSCodeIPCClient.getMainDiagnostics(socketPath: entry.socketPath) else {
                Log.focus.debug("VSCodeIPC: getMainDiagnostics failed")
                continue
            }

            // targetPath に完全一致するウィンドウを探す
            // git worktree の場合も考慮してプレフィックスマッチも試みる
            let matchedWindow = diagnostics.windows.first { window in
                window.folderPaths.contains { folderPath in
                    folderPath == targetPath || targetPath.hasPrefix(folderPath + "/")
                }
            }

            guard let window = matchedWindow else {
                Log.focus.debug("VSCodeIPC: no matching window for \(targetPath, privacy: .public)")
                Log.focus.debug("VSCodeIPC: available paths: \(diagnostics.windows.flatMap(\.folderPaths), privacy: .public)")
                continue
            }

            Log.focus.debug("VSCodeIPC: matched window id=\(window.id) title=\(window.title, privacy: .public)")

            // launch.start() でウィンドウをフォーカス（app.focus({steal:true}) 相当）
            let focused = VSCodeIPCClient.focusWindow(folderPath: targetPath, socketPath: entry.socketPath)
            Log.focus.debug("VSCodeIPC: launch.start result=\(focused)")
            return focused
        }
        return false
    }

    // MARK: - git worktree パス解析

    /// git worktree パスから親リポジトリ名を抽出する。
    ///
    /// `/.worktrees/` セグメントより前の最後のパスコンポーネントを返す。
    /// worktree でない通常のパスには `nil` を返す。
    private static func extractWorktreeParentName(from path: String) -> String? {
        guard let range = path.range(of: "/.worktrees/") else { return nil }
        let parentPath = String(path[..<range.lowerBound])
        let parentName = (parentPath as NSString).lastPathComponent
        return parentName.isEmpty ? nil : parentName
    }

    // MARK: - IPC Handle 検出

    /// `VSCODE_GIT_IPC_HANDLE` から Code Helper Plugin プロセスを特定し、
    /// そのプロセスの `PWD` 環境変数（= ワークスペースパス）を返す。
    ///
    /// ソケットはウィンドウごとにユニークなため、複数ウィンドウがある場合でも
    /// 正しいウィンドウを特定できる。
    private static func detectPluginPwdFromIpcHandle() -> String? {
        guard let ipcHandle = ProcessInfo.processInfo.environment["VSCODE_GIT_IPC_HANDLE"],
              let socketId = extractSocketId(from: ipcHandle),
              let pluginPid = ProcessUtils.findPidWithUnixSocket(containing: "vscode-git-\(socketId)")
        else {
            return nil
        }
        return ProcessUtils.getProcessPwd(pid: pluginPid)
    }

    /// `vscode-git-{socketId}.sock` 形式のパスから socketId を抽出する。
    private static func extractSocketId(from path: String) -> String? {
        let pattern = "vscode-git-([a-f0-9]+)\\.sock"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path)
        else {
            return nil
        }
        return String(path[range])
    }
}
