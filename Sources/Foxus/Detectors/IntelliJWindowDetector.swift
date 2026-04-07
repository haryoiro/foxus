import AppKit
import ApplicationServices
import Foundation

/// IntelliJ/JetBrains IDEウィンドウを特定するためのユーティリティ
public enum IntelliJWindowDetector: FocusDetector {

    /// FocusDetector プロトコル準拠: env は無視して cwd のみ使用
    public static func focusCurrentWindow(cwd: String?, env: [String: String]) -> Bool {
        focusCurrentWindow(cwd: cwd)
    }


    /// JetBrains製品のバンドルID一覧
    private static var bundleIds: [String] { BundleIDRegistry.jetBrainsBundleIds }

    /// IntelliJ環境からウィンドウを特定してフォーカス
    /// - Parameter cwd: 作業ディレクトリ（指定された場合はこれを優先してウィンドウを特定）
    /// - Returns: フォーカスに成功した場合はtrue
    public static func focusCurrentWindow(cwd: String? = nil) -> Bool {
        // 方法1: 明示的に指定されたcwdからプロジェクト名でマッチング（最も確実）
        if let cwd = cwd {
            let projectName = (cwd as NSString).lastPathComponent
            if !projectName.isEmpty {
                if WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                    focusTerminalTab()
                    return true
                }
            }
        }

        // 方法2: __CFBundleIdentifier + 親プロセスのcwdからプロジェクトを特定
        if let bundleId = ProcessInfo.processInfo.environment["__CFBundleIdentifier"],
            bundleIds.contains(bundleId) {
            if let parentCwd = ProcessUtils.getParentCwd() {
                let projectName = (parentCwd as NSString).lastPathComponent
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                for app in apps where WindowFocus.focusWindowInApp(app, matchingTitle: projectName) {
                    focusTerminalTab()
                    return true
                }
            }
            // バンドルIDが分かっているのでそのアプリにフォーカス
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = apps.first {
                app.activate(options: [.activateIgnoringOtherApps])
                focusTerminalTab()
                return true
            }
        }

        // 方法3: 親プロセスのcwdからプロジェクトを特定（全IDE検索）
        if let parentCwd = ProcessUtils.getParentCwd() {
            let projectName = (parentCwd as NSString).lastPathComponent
            if !projectName.isEmpty {
                if WindowFocus.focusWindowByTitle(projectName, bundleIds: bundleIds) {
                    focusTerminalTab()
                    return true
                }
            }
        }

        // 方法4: TTYから特定
        if let windowTitle = ProcessUtils.detectWindowTitleFromTty() {
            if WindowFocus.focusWindowByTitle(windowTitle, bundleIds: bundleIds) {
                focusTerminalTab()
                return true
            }
        }

        // 方法5: フォールバック - JetBrains IDEアプリにフォーカス
        return WindowFocus.focusAnyApp(bundleIds: bundleIds)
    }

    // MARK: - ターミナルタブフォーカス（ideScript）

    /// `idea ideScript` 経由で正しいターミナルタブをフォーカスする。
    ///
    /// 仕組み:
    /// 1. 祖先プロセスを辿って JetBrains IDE の直接子シェルを特定
    /// 2. IDE の全シェル子プロセスをPID昇順で列挙（= タブの順序）
    /// 3. 自分の祖先が何番目かを特定 → そのインデックスのタブを `ContentManager` で選択
    private static func focusTerminalTab() {
        // JetBrains IDE のPIDを特定
        guard let idePid = findJetBrainsIdePid() else {
            Log.focus.debug("IntelliJTerminalTab: IDE PID が見つかりません")
            return
        }

        // IDE のシェル子プロセスを列挙
        let shellChildren = ProcessUtils.findShellChildren(of: idePid)
        guard !shellChildren.isEmpty else {
            Log.focus.debug("IntelliJTerminalTab: IDE のシェル子プロセスが見つかりません")
            return
        }

        // 自分の祖先のうち IDE の直接子であるものを探す
        guard let ancestorShellPid = ProcessUtils.findAncestorWithParent(idePid) else {
            Log.focus.debug("IntelliJTerminalTab: 祖先に IDE の直接子が見つかりません")
            return
        }

        // タブインデックスを特定
        guard let tabIndex = shellChildren.firstIndex(of: ancestorShellPid) else {
            Log.focus.debug("IntelliJTerminalTab: 祖先PID \(ancestorShellPid) がシェル一覧に見つかりません")
            return
        }

        Log.focus.debug("IntelliJTerminalTab: tabIndex=\(tabIndex) (PID=\(ancestorShellPid))")

        // idea バイナリのパスを取得
        guard let ideaBinaryPath = findIdeaBinaryPath(idePid: idePid) else {
            Log.focus.debug("IntelliJTerminalTab: idea バイナリが見つかりません")
            return
        }

        // Kotlin スクリプトを生成して実行
        let script = """
        import com.intellij.openapi.project.ProjectManager
        import com.intellij.openapi.wm.ToolWindowManager

        val project = ProjectManager.getInstance().openProjects.firstOrNull()
        if (project != null) {
            val terminal = ToolWindowManager.getInstance(project).getToolWindow("Terminal")
            if (terminal != null) {
                terminal.activate {
                    val cm = terminal.contentManager
                    val target = cm.getContent(\(tabIndex))
                    if (target != null) {
                        cm.setSelectedContent(target, true)
                    }
                }
            }
        }
        """

        let scriptPath = NSTemporaryDirectory() + "foxus_ij_tab_\(ProcessInfo.processInfo.processIdentifier).kts"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            _ = ProcessUtils.runCommand(ideaBinaryPath, arguments: ["ideScript", scriptPath], timeout: 10.0)
            try? FileManager.default.removeItem(atPath: scriptPath)
            Log.focus.debug("IntelliJTerminalTab: ideScript 実行完了")
        } catch {
            Log.focus.warning("IntelliJTerminalTab: スクリプト書き込み失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 実行中の JetBrains IDE の PID を返す。
    private static func findJetBrainsIdePid() -> pid_t? {
        for bundleId in bundleIds {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = apps.first {
                return app.processIdentifier
            }
        }
        return nil
    }

    /// IDE の PID から `idea` バイナリのパスを特定する。
    private static func findIdeaBinaryPath(idePid: pid_t) -> String? {
        // 実行中のプロセスのパスから Contents/MacOS/idea を推測
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier == idePid }
        if let app = apps.first, let bundleURL = app.bundleURL {
            let ideaPath = bundleURL.appendingPathComponent("Contents/MacOS/idea").path
            if FileManager.default.isExecutableFile(atPath: ideaPath) {
                return ideaPath
            }
        }
        return nil
    }
}
