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
public enum VSCodeWindowDetector: FocusDetector {

    private static var bundleIds: [String] { BundleIDRegistry.vscodeBundleIds }

    /// VSCode ウィンドウを特定してフォーカスする。
    /// - Parameter cwd: hooks JSON から渡される作業ディレクトリ
    /// - Returns: 正しいウィンドウへのフォーカスに成功した場合は `true`
    public static func focusCurrentWindow(
        cwd: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        Log.focus.debug("VSCode: focusCurrentWindow cwd=\(cwd ?? "nil", privacy: .public)")

        // 方法1: VSCode IPC ソケット経由でウィンドウを特定（タイトルマッチ不要）
        // folderURIs.path が cwd と完全一致するウィンドウを探す
        if let cwd = cwd {
            let result = focusViaIPC(targetPath: cwd)
            Log.focus.debug("VSCode: 方法1(IPC) result=\(result)")
            if result { return true }
        }

        // 方法2: VSCODE_GIT_IPC_HANDLE からウィンドウを特定
        // ソケット保持プロセスの PWD = そのウィンドウのワークスペースパス
        if let pluginPwd = detectPluginPwdFromIpcHandle(env: env) {
            let projectName = (pluginPwd as NSString).lastPathComponent
            Log.focus.debug("VSCode: 方法2(IPC_HANDLE) projectName=\(projectName, privacy: .public)")
            if !projectName.isEmpty,
               WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                _ = focusTerminalTab(bundleIds: bundleIds)
                return true
            }
        }

        // 方法3: cwd のフォルダ名でウィンドウタイトルをマッチ
        if let cwd = cwd {
            let projectName = (cwd as NSString).lastPathComponent
            Log.focus.debug("VSCode: 方法3(titleMatch) projectName=\(projectName, privacy: .public)")
            if !projectName.isEmpty,
               WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                _ = focusTerminalTab(bundleIds: bundleIds)
                return true
            }
        }

        // 方法4: git worktree 内の場合、親リポジトリ名でマッチ
        if let cwd = cwd, let parentRepoName = extractWorktreeParentName(from: cwd) {
            Log.focus.debug("VSCode: 方法4(worktree) parentRepoName=\(parentRepoName, privacy: .public)")
            if WindowFocus.focusWindowByTitle(parentRepoName, bundleIds: bundleIds) {
                _ = focusTerminalTab(bundleIds: bundleIds)
                return true
            }
        }

        // 方法5: TTY からシェルの cwd を取得してウィンドウタイトルを推測
        if let windowTitle = ProcessUtils.detectWindowTitleFromTty() {
            Log.focus.debug("VSCode: 方法5(TTY) windowTitle=\(windowTitle, privacy: .public)")
            if WindowFocus.focusWindowByTitle(windowTitle, bundleIds: bundleIds) {
                _ = focusTerminalTab(bundleIds: bundleIds)
                return true
            }
        }

        // 方法6: フォールバック — ウィンドウ特定を諦め、アプリ全体をアクティブ化
        Log.focus.debug("VSCode: 方法6(fallback) アプリ全体アクティブ化")
        return WindowFocus.focusAnyApp(bundleIds: bundleIds)
    }

    // MARK: - ターミナルタブフォーカス（Accessibility API）

    /// AXツリーからターミナルタブを検索し、祖先プロセスの `p_comm` にマッチするタブをフォーカスする。
    ///
    /// 前提条件:
    /// - VSCode の `terminal.integrated.tabs.title` に `${sequence}` または `${process}` を含む設定が必要
    /// - `AXEnhancedUserInterface` を一時的に有効化してChromiumのAXツリーを展開する
    ///
    /// タブの `AXDescription` は `"ターミナル {N} {title}"` 形式で、
    /// `{title}` にフォアグラウンドプロセスの `p_comm` が含まれる。
    private static func focusTerminalTab(bundleIds: [String]) -> Bool {
        guard let pcomm = ProcessUtils.getAncestorPComm(), !pcomm.isEmpty else {
            Log.focus.debug("VSCodeTerminalTab: 祖先 p_comm 取得失敗")
            return false
        }

        // シェル名の場合はマッチの精度が低いためスキップ
        if ProcessUtils.shellNames.contains(pcomm) {
            Log.focus.debug("VSCodeTerminalTab: p_comm がシェル名 (\(pcomm, privacy: .public))、タブマッチをスキップ")
            return false
        }

        Log.focus.debug("VSCodeTerminalTab: p_comm=\(pcomm, privacy: .public) でタブ検索")

        for bundleId in bundleIds {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            for app in apps {
                if let result = focusTerminalTabInApp(app, pcomm: pcomm) {
                    return result
                }
            }
        }
        return false
    }

    /// 指定アプリのAXツリーでターミナルタブを検索・フォーカスする。
    private static func focusTerminalTabInApp(_ app: NSRunningApplication, pcomm: String) -> Bool? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // ChromiumのAXツリーを展開
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        defer {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, false as CFTypeRef)
        }

        // AXツリー展開に時間がかかるため待機
        Thread.sleep(forTimeInterval: 3.0)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }

        for window in windows {
            var tabs: [(desc: String, element: AXUIElement)] = []
            collectTerminalTabs(window, depth: 0, results: &tabs)

            guard !tabs.isEmpty else { continue }

            // p_comm にマッチするタブを検索
            for tab in tabs where tab.desc.contains(pcomm) {
                Log.focus.debug("VSCodeTerminalTab: マッチ: \(tab.desc, privacy: .public)")

                // 子要素の monaco-icon-label を AXPress でクリック
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(tab.element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement],
                      let iconLabel = children.first
                else { continue }

                let result = AXUIElementPerformAction(iconLabel, kAXPressAction as CFString)
                Log.focus.debug("VSCodeTerminalTab: AXPress result=\(result == .success)")
                return result == .success
            }
        }
        return nil
    }

    /// AXツリーを再帰探索してターミナルタブ要素を収集する。
    ///
    /// ターミナルタブは `AXDOMClassList` に `monaco-list-row` を含み、
    /// `AXDescription` が `"ターミナル"` で始まる `AXGroup` 要素。
    private static func collectTerminalTabs(
        _ element: AXUIElement,
        depth: Int,
        results: inout [(desc: String, element: AXUIElement)]
    ) {
        if depth > 40 { return }

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String ?? ""

        var clsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &clsRef)
        let cls = (clsRef as? [String] ?? []).joined(separator: " ")

        if cls.contains("monaco-list-row") && desc.contains("ターミナル") {
            results.append((desc: desc, element: element))
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }

        for child in children {
            collectTerminalTabs(child, depth: depth + 1, results: &results)
        }
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
                Log.focus.debug("VSCodeIPC: getMainDiagnostics 失敗 socket=\(entry.socketPath, privacy: .public)")
                continue
            }

            Log.focus.debug("VSCodeIPC: windows(\(diagnostics.windows.count))")
            for w in diagnostics.windows {
                Log.focus.debug("VSCodeIPC:   id=\(w.id) title=\(w.title, privacy: .public) folders=\(w.folderPaths, privacy: .public)")
            }

            let matchedWindow = diagnostics.windows.first { window in
                window.folderPaths.contains { fp in
                    fp == targetPath || targetPath.hasPrefix(fp + "/")
                }
            }

            guard let window = matchedWindow else {
                Log.focus.debug("VSCodeIPC: マッチなし targetPath=\(targetPath, privacy: .public)")
                continue
            }

            let folderPath = window.folderPaths.first { fp in
                fp == targetPath || targetPath.hasPrefix(fp + "/")
            } ?? targetPath
            Log.focus.debug("VSCodeIPC: マッチ id=\(window.id) pid=\(window.pid) folderPath=\(folderPath, privacy: .public)")
            let focused = VSCodeIPCClient.focusWindow(folderPath: folderPath, socketPath: entry.socketPath)
            Log.focus.debug("VSCodeIPC: launch.start result=\(focused)")

            if focused {
                // launch.start は VSCode 内部で非同期にウィンドウをキーにするため、
                // 処理完了を待ってから OS レベルでアプリをアクティブ化する
                Thread.sleep(forTimeInterval: 0.15)
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleId)
                // window.pid に対応するアプリを優先（Electron renderer）、なければ最初のメインプロセス
                let targetApp = apps.first(where: { $0.processIdentifier == pid_t(window.pid) }) ?? apps.first
                if let app = targetApp {
                    let activated = app.activate(options: [.activateIgnoringOtherApps])
                    Log.focus.debug("VSCodeIPC: activate(pid=\(app.processIdentifier)) result=\(activated)")
                }
            }
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
    private static func detectPluginPwdFromIpcHandle(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let ipcHandle = env["VSCODE_GIT_IPC_HANDLE"],
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
