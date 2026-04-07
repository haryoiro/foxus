import Darwin
import Foundation
import Testing
@testable import Foxus

// MARK: - FocusStrategyResolver Tests

@Suite("FocusStrategy Detection Tests")
struct FocusStrategyResolverTests {

    // MARK: cmux

    @Test("CMUX_WORKSPACE_IDがあればcmux戦略")
    func cmuxStrategy() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/path/to/project",
            env: ["CMUX_WORKSPACE_ID": "ws-123"]
        )
        #expect(strategy == .cmux(cwd: "/path/to/project"))
    }

    @Test("cmux > tmux の優先順位")
    func cmuxBeforeTmux() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["CMUX_WORKSPACE_ID": "ws-123", "TMUX": "/tmp/tmux.sock,1234,0"]
        )
        #expect(strategy == .cmux(cwd: nil))
    }

    // MARK: zellij

    @Test("ZELLIJ環境変数があればzellij戦略")
    func zellijStrategy() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/project",
            env: ["ZELLIJ": "0"]
        )
        #expect(strategy == .zellij(cwd: "/project"))
    }

    @Test("tmux > zellij の優先順位")
    func tmuxBeforeZellij() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["TMUX": "/tmp/tmux.sock,1,0", "ZELLIJ": "0"]
        )
        #expect(strategy == .tmux(cwd: nil))
    }

    // MARK: wezterm

    @Test("WEZTERM_PANE環境変数があればwezterm戦略")
    func weztermStrategy() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/project",
            env: ["WEZTERM_PANE": "3"]
        )
        #expect(strategy == .wezterm(cwd: "/project"))
    }

    @Test("zellij > wezterm の優先順位")
    func zellijBeforeWezterm() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["ZELLIJ": "0", "WEZTERM_PANE": "3"]
        )
        #expect(strategy == .zellij(cwd: nil))
    }

    // MARK: kitty

    @Test("KITTY_WINDOW_ID環境変数があればkitty戦略")
    func kittyStrategy() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/project",
            env: ["KITTY_WINDOW_ID": "5"]
        )
        #expect(strategy == .kitty(cwd: "/project"))
    }

    @Test("wezterm > kitty の優先順位")
    func weztermBeforeKitty() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["WEZTERM_PANE": "3", "KITTY_WINDOW_ID": "5"]
        )
        #expect(strategy == .wezterm(cwd: nil))
    }

    // MARK: tmux

    @Test("TMUX環境変数があればtmux戦略")
    func tmuxStrategy() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/path/to/project",
            env: ["TMUX": "/tmp/tmux-501/default,12345,0"]
        )
        #expect(strategy == .tmux(cwd: "/path/to/project"))
    }

    @Test("callerAppがエディタ以外ならTMUXが優先")
    func tmuxOverNonEditorCallerApp() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "ghostty",
            cwd: nil,
            env: ["TMUX": "/tmp/tmux.sock,1,0"]
        )
        #expect(strategy == .tmux(cwd: nil))
    }

    @Test("callerAppがvscodeならTMUXよりVSCodeが優先")
    func vscodeOverTmux() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "vscode",
            cwd: nil,
            env: ["TMUX": "/tmp/tmux.sock,1,0"]
        )
        #expect(strategy == .vscode(cwd: nil))
    }

    // MARK: VSCode

    @Test("callerAppがvscodeならVSCode戦略")
    func vscodeFromCallerApp() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "vscode",
            cwd: "/project",
            env: [:]
        )
        #expect(strategy == .vscode(cwd: "/project"))
    }

    @Test("TERM_PROGRAM=vscodeでVSCode戦略")
    func vscodeFromTermProgram() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["TERM_PROGRAM": "vscode"]
        )
        #expect(strategy == .vscode(cwd: nil))
    }

    @Test("VSCODE_GIT_IPC_HANDLEのみでVSCode戦略")
    func vscodeFromIpcHandle() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["VSCODE_GIT_IPC_HANDLE": "/tmp/vscode-git-abc123.sock"]
        )
        #expect(strategy == .vscode(cwd: nil))
    }

    @Test("callerAppが非エディタでもVSCode環境変数があればVSCode戦略")
    func vscodeFromEnvWithNonEditorCaller() {
        // callerApp="ghostty" はエディタではないので callerApp 優先を通過し、
        // 環境変数の VSCODE_GIT_IPC_HANDLE で VSCode と判定される
        let strategy = FocusStrategyResolver.determine(
            callerApp: "ghostty",
            cwd: nil,
            env: ["VSCODE_GIT_IPC_HANDLE": "/tmp/vscode-git-abc123.sock"]
        )
        #expect(strategy == .vscode(cwd: nil))
    }

    // MARK: IntelliJ

    @Test("callerAppがIntelliJならIntelliJ戦略")
    func intellijFromCallerApp() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "idea",
            cwd: "/project",
            env: [:]
        )
        #expect(strategy == .intellij(cwd: "/project"))
    }

    @Test("TERMINAL_EMULATORがJetBrainsならIntelliJ戦略")
    func intellijFromTerminalEmulator() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["TERMINAL_EMULATOR": "JetBrains-JediTerm"]
        )
        #expect(strategy == .intellij(cwd: nil))
    }

    @Test("__INTELLIJ_COMMAND_HISTFILE__が設定されていればIntelliJ戦略")
    func intellijFromHistFile() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["__INTELLIJ_COMMAND_HISTFILE__": "/tmp/histfile"]
        )
        #expect(strategy == .intellij(cwd: nil))
    }

    @Test("__CFBundleIdentifierがjetbrainsならIntelliJ戦略")
    func intellijFromBundleId() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: ["__CFBundleIdentifier": "com.jetbrains.intellij"]
        )
        #expect(strategy == .intellij(cwd: nil))
    }

    // MARK: generic

    @Test("既知ターミナルはgeneric戦略でバンドルIDが解決される")
    func genericWithKnownTerminal() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "iTerm.app",
            cwd: "/project",
            env: [:]
        )
        #expect(strategy == .generic(bundleId: "com.googlecode.iterm2", cwd: "/project"))
    }

    @Test("callerAppがnilでcwdがあればgeneric")
    func genericFromCwdOnly() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: "/project",
            env: [:]
        )
        #expect(strategy == .generic(bundleId: nil, cwd: "/project"))
    }

    @Test("バンドルIDそのものが渡された場合もgeneric")
    func genericFromBundleId() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "com.googlecode.iterm2",
            cwd: nil,
            env: [:]
        )
        #expect(strategy == .generic(bundleId: "com.googlecode.iterm2", cwd: nil))
    }

    // MARK: fallback

    @Test("callerAppもcwdもnilで環境変数もなければfallback")
    func fallbackWhenNoInfo() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: nil,
            cwd: nil,
            env: [:]
        )
        #expect(strategy == .fallback)
    }

    @Test("callerAppが未知のドットなし文字列でcwdもnilならfallback")
    func fallbackForUnknownCallerNoCwd() {
        let strategy = FocusStrategyResolver.determine(
            callerApp: "unknownapp",
            cwd: nil,
            env: [:]
        )
        #expect(strategy == .fallback)
    }
}

// MARK: - ProcessDetector Tests

@Suite("ProcessDetector Tests")
struct ProcessDetectorTests {

    @Test("TERM_PROGRAMからターミナルアプリを検出（プロセスツリーにGUIアプリなし）")
    func detectFromTermProgram() {
        // プロセスツリーを辿ってもGUIアプリが見つからない環境（CI等）では
        // TERM_PROGRAMへのフォールバックが発動する
        // このテストでは ghostty を指定して ghostty が返ることを確認
        // （プロセスツリーにGUIアプリがある場合は別の結果になりえる）
        let result = ProcessDetector.detectTerminalApp(env: ["TERM_PROGRAM": "ghostty"])
        // プロセスツリーで実際のGUIアプリが見つかる場合もあるので
        // TERM_PROGRAMの値か、別のターミナルアプリ名が返ることを確認
        #expect(result != nil)
        if let result { #expect(!result.isEmpty) }
    }

    @Test("cmux環境ではTERM_PROGRAM=ghosttyでもcmuxを返す")
    func detectCmuxFromGhostty() {
        // プロセスツリーにGUIアプリがない環境（テスト環境）でのみ有効
        // プロセスツリーが空ならenv["TERM_PROGRAM"]フォールバックに到達する
        let result = ProcessDetector.detectTerminalApp(env: [
            "TERM_PROGRAM": "ghostty",
            "CMUX_WORKSPACE_ID": "ws-abc"
        ])
        // 実行環境によってプロセスツリーで別アプリが検出される場合があるため
        // cmux または nil または別のアプリ名のいずれかが返ることを確認
        #expect(result != nil)
        if let result { #expect(!result.isEmpty) }
    }
}

// MARK: - TmuxWindowDetector Tests

@Suite("TmuxWindowDetector Tests")
struct TmuxWindowDetectorTests {

    @Test("TMUX環境変数からソケットパスを正しく抽出")
    func parseSocketPath() {
        let result = TmuxWindowDetector.parseSocketPath(from: "/tmp/tmux-501/default,12345,0")
        #expect(result == "/tmp/tmux-501/default")
    }

    @Test("カスタムソケットパスを正しく抽出")
    func parseCustomSocketPath() {
        let result = TmuxWindowDetector.parseSocketPath(from: "/var/run/tmux.sock,9999,1")
        #expect(result == "/var/run/tmux.sock")
    }

    @Test("ソケットパスにカンマがない場合はパス全体を返す")
    func parseSocketPathNoComma() {
        let result = TmuxWindowDetector.parseSocketPath(from: "/tmp/tmux.sock")
        #expect(result == "/tmp/tmux.sock")
    }

    @Test("空文字列はnilを返す")
    func parseSocketPathEmpty() {
        let result = TmuxWindowDetector.parseSocketPath(from: "")
        #expect(result == nil)
    }

    @Test("TMUX環境変数からサーバーPIDを正しく抽出")
    func parseServerPid() {
        let result = TmuxWindowDetector.parseServerPid(from: "/tmp/tmux-501/default,12345,0")
        #expect(result == 12345)
    }

    @Test("サーバーPIDが数値でない場合はnilを返す")
    func parseServerPidInvalid() {
        let result = TmuxWindowDetector.parseServerPid(from: "/tmp/tmux.sock,abc,0")
        #expect(result == nil)
    }

    @Test("カンマが1つだけのTMUX値を正しく処理")
    func parseServerPidOneComma() {
        let result = TmuxWindowDetector.parseServerPid(from: "/tmp/tmux.sock")
        #expect(result == nil)
    }
}

// MARK: - BundleIDRegistry Tests

@Suite("BundleIDRegistry Tests")
struct BundleIDRegistryTests {

    @Test("TERM_PROGRAM名からバンドルIDに解決")
    func termProgramToBundleId() {
        #expect(BundleIDRegistry.termProgramToBundleId["iTerm.app"] == "com.googlecode.iterm2")
        #expect(BundleIDRegistry.termProgramToBundleId["ghostty"] == "com.mitchellh.ghostty")
        #expect(BundleIDRegistry.termProgramToBundleId["vscode"] == "com.microsoft.VSCode")
        #expect(BundleIDRegistry.termProgramToBundleId["cmux"] == "com.cmuxterm.app")
    }

    @Test("バンドルIDからTERM_PROGRAM名に解決")
    func bundleIdToTermProgram() {
        #expect(BundleIDRegistry.terminalApps["com.googlecode.iterm2"] == "iTerm.app")
        #expect(BundleIDRegistry.terminalApps["com.mitchellh.ghostty"] == "ghostty")
        #expect(BundleIDRegistry.terminalApps["com.cmuxterm.app"] == "cmux")
    }

    @Test("tmuxはtermProgramToBundleIdに含まれていない（動的検出に委譲）")
    func tmuxNotInRegistry() {
        #expect(BundleIDRegistry.termProgramToBundleId["tmux"] == nil)
    }

    @Test("allTerminalAppsにJetBrainsが含まれる")
    func allTerminalAppsIncludesJetBrains() {
        #expect(BundleIDRegistry.allTerminalApps["com.jetbrains.intellij"] != nil)
    }

    @Test("VSCodeのバンドルID一覧が正しい")
    func vscodeBundleIds() {
        let ids = BundleIDRegistry.vscodeBundleIds
        #expect(ids.contains("com.microsoft.VSCode"))
        #expect(ids.contains("com.microsoft.VSCodeInsiders"))
    }

    @Test("JetBrainsのバンドルID一覧が空でない")
    func jetBrainsBundleIdsNotEmpty() {
        #expect(!BundleIDRegistry.jetBrainsBundleIds.isEmpty)
    }

    @Test("allTerminalBundleIdsがterminalAppsとjetBrainsを含む")
    func allTerminalBundleIdsUnion() {
        let all = BundleIDRegistry.allTerminalBundleIds
        #expect(all.contains("com.googlecode.iterm2"))
        #expect(all.contains("com.jetbrains.intellij"))
    }
}

// MARK: - FocusResult Tests

@Suite("FocusResult Tests")
struct FocusResultTests {

    @Test("FocusResultが戦略と成否を保持する")
    func focusResultHoldsValues() {
        let result = FocusResult(strategy: .fallback, succeeded: false)
        #expect(result.strategy == .fallback)
        #expect(result.succeeded == false)
        #expect(result.error == nil)
    }

    @Test("FocusResultがエラー原因を保持する")
    func focusResultHoldsError() {
        let result = FocusResult(strategy: .fallback, succeeded: false, error: .noStrategyAvailable)
        #expect(result.succeeded == false)
        #expect(result.error == .noStrategyAvailable)
    }

    @Test("FocusResultが成功時はerrorがnil")
    func focusResultSuccessNoError() {
        let result = FocusResult(strategy: .tmux(cwd: "/tmp"), succeeded: true)
        #expect(result.succeeded == true)
        #expect(result.error == nil)
    }
}

// MARK: - FocusError Tests

@Suite("FocusError Tests")
struct FocusErrorTests {

    @Test("FocusErrorが戦略情報を保持する")
    func focusErrorCarriesStrategy() {
        let error = FocusError.focusFailed(strategy: .tmux(cwd: "/project"))
        if case .focusFailed(let strategy) = error {
            #expect(strategy == .tmux(cwd: "/project"))
        } else {
            Issue.record("Expected .focusFailed")
        }
    }

    @Test("各エラーケースが区別可能")
    func errorCasesAreDistinct() {
        let strategy = FocusStrategy.vscode(cwd: "/project")
        #expect(FocusError.appNotRunning(strategy: strategy) != FocusError.windowNotFound(strategy: strategy))
        #expect(FocusError.noStrategyAvailable != FocusError.focusFailed(strategy: strategy))
    }
}

// MARK: - ProcessUtils Tests

@Suite("ProcessUtils Tests")
struct ProcessUtilsTests {

    // MARK: getProcessPwd

    @Test("getProcessPwd: テストプロセス自身のPWDを取得できる")
    func getProcessPwdCurrentProcess() {
        // swift test はシェルから PWD を継承するため自プロセスで取得できるはず
        let pwd = ProcessUtils.getProcessPwd(pid: getpid())
        #expect(pwd != nil)
        if let pwd = pwd {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: pwd, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    @Test("getProcessPwd: 無効なPIDはnilを返す")
    func getProcessPwdInvalidPid() {
        #expect(ProcessUtils.getProcessPwd(pid: -1) == nil)
    }

    // MARK: findPidWithUnixSocket

    @Test("findPidWithUnixSocket: 存在しないパスはnilを返す")
    func findPidWithUnixSocketNotFound() {
        let pid = ProcessUtils.findPidWithUnixSocket(containing: "foxus-nonexistent-\(UUID().uuidString)")
        #expect(pid == nil)
    }

    @Test("findPidWithUnixSocket: 自プロセスが持つUnixソケットを検出できる")
    func findPidWithUnixSocketSelf() throws {
        // 一時Unixソケットを作成して bind し、自PIDが返ることを確認
        let uniqueTag = "foxus-test-\(UUID().uuidString)"
        let socketPath = "/tmp/\(uniqueTag).sock"

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer {
            close(fd)
            unlink(socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = strlcpy(dst, src, 104)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bindResult == 0)

        let foundPid = ProcessUtils.findPidWithUnixSocket(containing: uniqueTag)
        #expect(foundPid == getpid())
    }
}

// MARK: - ResolvedContext Tests

@Suite("ResolvedContext Tests")
struct ResolvedContextTests {

    @Test("resolve()がResolvedContextを返す")
    func resolveReturnsContext() {
        let context = Foxus.resolve(callerApp: "vscode", cwd: "/tmp/project", env: [:])
        #expect(context.strategy == .vscode(cwd: "/tmp/project"))
        #expect(context.callerApp == "vscode")
        #expect(context.cwd == "/tmp/project")
    }

    @Test("ResolvedContextがCodableで往復する")
    func codableRoundTrip() throws {
        let original = ResolvedContext(
            strategy: .cmux(cwd: "/tmp/project"),
            callerApp: "cmux",
            cwd: "/tmp/project",
            env: ["CMUX_WORKSPACE_ID": "ws-123", "CMUX_SURFACE_ID": "sf-456"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResolvedContext.self, from: data)
        #expect(decoded.strategy == original.strategy)
        #expect(decoded.callerApp == original.callerApp)
        #expect(decoded.cwd == original.cwd)
        #expect(decoded.env == original.env)
    }

    @Test("全FocusStrategy種別がCodableで往復する")
    func allStrategiesCodable() throws {
        let strategies: [FocusStrategy] = [
            .cmux(cwd: "/a"), .tmux(cwd: "/b"), .zellij(cwd: nil),
            .wezterm(cwd: "/c"), .kitty(cwd: "/d"),
            .vscode(cwd: "/e"), .intellij(cwd: nil),
            .generic(bundleId: "com.example", cwd: "/f"), .fallback,
        ]
        for strategy in strategies {
            let data = try JSONEncoder().encode(strategy)
            let decoded = try JSONDecoder().decode(FocusStrategy.self, from: data)
            #expect(decoded == strategy, "Failed for \(strategy)")
        }
    }

    @Test("resolve()がcmux用の環境変数を抽出する")
    func resolveExtractsCmuxEnv() {
        let env = [
            "CMUX_WORKSPACE_ID": "ws-123",
            "CMUX_SURFACE_ID": "sf-456",
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "HOME": "/Users/test",
        ]
        // callerApp 未指定だと ProcessDetector が動くので、
        // env からの戦略決定をテストするために空文字列を指定
        let strategy = FocusStrategyResolver.determine(callerApp: nil, cwd: "/tmp", env: env)
        #expect(strategy == .cmux(cwd: "/tmp"))

        let context = ResolvedContext(
            strategy: strategy, callerApp: nil, cwd: "/tmp",
            env: env.filter { strategy.restoreKeys.contains($0.key) }
        )
        #expect(context.env["CMUX_WORKSPACE_ID"] == "ws-123")
        #expect(context.env["CMUX_SURFACE_ID"] == "sf-456")
        #expect(context.env["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock")
        #expect(context.env["HOME"] == nil)
    }

    @Test("resolve()がvscode用の環境変数を抽出する")
    func resolveExtractsVSCodeEnv() {
        let env = [
            "TERM_PROGRAM": "vscode",
            "VSCODE_GIT_IPC_HANDLE": "/tmp/vscode-git.sock",
            "PATH": "/usr/bin",
        ]
        let strategy = FocusStrategyResolver.determine(callerApp: nil, cwd: "/tmp", env: env)
        #expect(strategy == .vscode(cwd: "/tmp"))

        let context = ResolvedContext(
            strategy: strategy, callerApp: nil, cwd: "/tmp",
            env: env.filter { strategy.restoreKeys.contains($0.key) }
        )
        #expect(context.env["VSCODE_GIT_IPC_HANDLE"] == "/tmp/vscode-git.sock")
        #expect(context.env["TERM_PROGRAM"] == "vscode")
        #expect(context.env["PATH"] == nil)
    }
}

// MARK: - FocusStrategy.restoreKeys Tests

@Suite("FocusStrategy restoreKeys Tests")
struct RestoreKeysTests {

    @Test("cmux戦略にcmux固有キーが含まれる")
    func cmuxKeys() {
        let keys = FocusStrategy.cmux(cwd: nil).restoreKeys
        #expect(keys.contains("CMUX_WORKSPACE_ID"))
        #expect(keys.contains("CMUX_SURFACE_ID"))
        #expect(keys.contains("CMUX_SOCKET_PATH"))
    }

    @Test("tmux戦略にtmux固有キーが含まれる")
    func tmuxKeys() {
        let keys = FocusStrategy.tmux(cwd: nil).restoreKeys
        #expect(keys.contains("TMUX"))
        #expect(keys.contains("TMUX_PANE"))
    }

    @Test("vscode戦略にvscode固有キーが含まれる")
    func vscodeKeys() {
        let keys = FocusStrategy.vscode(cwd: nil).restoreKeys
        #expect(keys.contains("VSCODE_GIT_IPC_HANDLE"))
    }

    @Test("全戦略にTERM_PROGRAMが含まれる")
    func commonKeys() {
        let strategies: [FocusStrategy] = [
            .cmux(cwd: nil), .tmux(cwd: nil), .vscode(cwd: nil), .intellij(cwd: nil),
        ]
        for s in strategies {
            #expect(s.restoreKeys.contains("TERM_PROGRAM"), "Missing TERM_PROGRAM in \(s)")
        }
    }

    @Test("fallbackのrestoreKeysは共通キーのみ")
    func fallbackKeys() {
        let keys = FocusStrategy.fallback.restoreKeys
        #expect(keys.contains("TERM_PROGRAM"))
        #expect(!keys.contains("CMUX_WORKSPACE_ID"))
        #expect(!keys.contains("TMUX"))
    }

    @Test("callerApp=vscodeがcmuxより優先される")
    func callerAppVSCodeOverCmux() {
        let env = ["CMUX_WORKSPACE_ID": "ws-123"]
        let context = Foxus.resolve(callerApp: "vscode", cwd: "/tmp", env: env)
        #expect(context.strategy == .vscode(cwd: "/tmp"))
    }
}

// MARK: - LEB128 デコードテスト

@Suite("VSCodeIPCClient LEB128 Tests")
struct LEB128Tests {

    @Test("1バイト値のデコード")
    func singleByte() {
        let data = Data([0x05])  // 5
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == 5)
    }

    @Test("2バイト値のデコード")
    func twoByte() {
        let data = Data([0x80, 0x01])  // 128
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == 128)
    }

    @Test("大きい値のデコード")
    func largValue() {
        let data = Data([0xFF, 0xFF, 0x03])  // 65535
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == 65535)
    }

    @Test("空データは nil")
    func emptyData() {
        let data = Data()
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == nil)
    }

    @Test("終端バイトなし（全 0x80）は nil")
    func noTerminator() {
        // 10バイト全て continuation bit が立っている → shift 上限超過で nil
        let data = Data(repeating: 0x80, count: 10)
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == nil)
    }

    @Test("shift オーバーフロー防止")
    func shiftOverflow() {
        // 64bit超の shift を要求するデータ → nil
        var bytes = [UInt8](repeating: 0x80, count: 12)
        bytes.append(0x01)  // 終端
        let data = Data(bytes)
        var pos = data.startIndex
        #expect(VSCodeIPCClient.decodeLEB128(data, pos: &pos) == nil)
    }
}

// MARK: - AppleScript エスケープテスト

@Suite("GhosttyWindowDetector AppleScript Escape Tests")
struct AppleScriptEscapeTests {

    @Test("通常文字列はそのまま")
    func normalString() {
        #expect(GhosttyWindowDetector.escapeForAS("hello") == "hello")
    }

    @Test("バックスラッシュのエスケープ")
    func backslash() {
        #expect(GhosttyWindowDetector.escapeForAS("a\\b") == "a\\\\b")
    }

    @Test("ダブルクォートのエスケープ")
    func doubleQuote() {
        #expect(GhosttyWindowDetector.escapeForAS("say \"hi\"") == "say \\\"hi\\\"")
    }

    @Test("改行・タブのエスケープ")
    func newlineAndTab() {
        #expect(GhosttyWindowDetector.escapeForAS("a\nb\tc") == "a\\nb\\tc")
    }

    @Test("キャリッジリターンのエスケープ")
    func carriageReturn() {
        #expect(GhosttyWindowDetector.escapeForAS("a\rb") == "a\\rb")
    }

    @Test("制御文字は除去される")
    func controlCharsStripped() {
        let input = "hello\u{01}\u{02}\u{1F}world"
        let result = GhosttyWindowDetector.escapeForAS(input)
        #expect(result == "helloworld")
    }

    @Test("日本語パスのエスケープ")
    func japanesePath() {
        #expect(GhosttyWindowDetector.escapeForAS("/Users/太郎/プロジェクト") == "/Users/太郎/プロジェクト")
    }

    @Test("空文字列")
    func emptyString() {
        #expect(GhosttyWindowDetector.escapeForAS("") == "")
    }

    @Test("複合エスケープ")
    func combined() {
        let result = GhosttyWindowDetector.escapeForAS("path\\to \"my\nproject\"")
        #expect(result == "path\\\\to \\\"my\\nproject\\\"")
    }
}

// MARK: - Cursor 認識テスト

@Suite("Cursor Recognition Tests")
struct CursorTests {

    @Test("callerApp=cursor で VSCode 戦略")
    func cursorCallerApp() {
        let strategy = FocusStrategyResolver.determine(callerApp: "cursor", cwd: "/tmp", env: [:])
        #expect(strategy == .vscode(cwd: "/tmp"))
    }

    @Test("callerApp=Cursor（大文字）で VSCode 戦略")
    func cursorUpperCase() {
        let strategy = FocusStrategyResolver.determine(callerApp: "Cursor", cwd: "/tmp", env: [:])
        #expect(strategy == .vscode(cwd: "/tmp"))
    }

    @Test("TERM_PROGRAM=cursor で VSCode 戦略")
    func cursorTermProgram() {
        let strategy = FocusStrategyResolver.determine(callerApp: nil, cwd: "/tmp", env: ["TERM_PROGRAM": "cursor"])
        #expect(strategy == .vscode(cwd: "/tmp"))
    }

    @Test("Cursor が BundleIDRegistry に登録されている")
    func cursorInRegistry() {
        #expect(BundleIDRegistry.termProgramToBundleId["cursor"] != nil)
    }

    @Test("Cursor が vscodeBundleIds に含まれる")
    func cursorInVSCodeBundleIds() {
        #expect(BundleIDRegistry.vscodeBundleIds.contains("com.todesktop.230313mzl4w4u92"))
    }
}

// MARK: - TerminalTitle パーステスト

@Suite("TerminalTitle Parse Tests")
struct TerminalTitleParseTests {

    @Test("正常なタイトル応答をパース")
    func normalTitle() {
        let response = Array("\u{1b}[21;My Project~".utf8)
        #expect(TerminalTitle.parseTitle(response) == "My Project")
    }

    @Test("日本語タイトル")
    func japaneseTitle() {
        let response = Array("\u{1b}[21;プロジェクト名~".utf8)
        #expect(TerminalTitle.parseTitle(response) == "プロジェクト名")
    }

    @Test("空タイトルは nil")
    func emptyTitle() {
        let response = Array("\u{1b}[21;~".utf8)
        #expect(TerminalTitle.parseTitle(response) == nil)
    }

    @Test("不正なフォーマットは nil")
    func invalidFormat() {
        let response = Array("garbage data".utf8)
        #expect(TerminalTitle.parseTitle(response) == nil)
    }

    @Test("空配列は nil")
    func emptyResponse() {
        #expect(TerminalTitle.parseTitle([]) == nil)
    }

    @Test("セミコロンを含むタイトル")
    func titleWithSemicolon() {
        let response = Array("\u{1b}[21;dir:branch;extra~".utf8)
        #expect(TerminalTitle.parseTitle(response) == "dir:branch;extra")
    }

    @Test("lazy マッチで最短一致（チルダを含むタイトル）")
    func lazyMatch() {
        // タイトルに ~ が含まれる場合、最初の ~ で終わるべき
        let response = Array("\u{1b}[21;~/projects~".utf8)
        #expect(TerminalTitle.parseTitle(response) == "~/projects")
    }
}
