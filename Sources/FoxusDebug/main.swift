import Foundation
import Foxus

// MARK: - foxus-debug
//
// 使い方:
//   swift run foxus-debug
//   swift run foxus-debug --dry-run
//   swift run foxus-debug --cwd /path/to/project
//   swift run foxus-debug --caller iTerm.app

// MARK: - 引数パース

var dryRun = false
var cwdOverride: String? = nil
var callerOverride: String? = nil

var args = CommandLine.arguments.dropFirst()
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dry-run":
        dryRun = true
    case "--cwd":
        cwdOverride = args.isEmpty ? nil : args.removeFirst()
    case "--caller":
        callerOverride = args.isEmpty ? nil : args.removeFirst()
    default:
        break
    }
}

// MARK: - 検出

let env = ProcessInfo.processInfo.environment
let callerApp = callerOverride ?? ProcessDetector.detectTerminalApp(env: env)
let cwd = cwdOverride ?? ProcessUtils.getCwdFromCurrentTty() ?? ProcessUtils.getParentCwd()
let strategy = FocusStrategyResolver.determine(callerApp: callerApp, cwd: cwd, env: env)

// MARK: - 出力

func label(_ s: String) -> String { "[\(s)]".padding(toLength: 12, withPad: " ", startingAt: 0) }

print("")
print("=== foxus-debug ===")
print("")
print("--- 環境変数 ---")
for key in ["TERM_PROGRAM", "TMUX", "TMUX_PANE", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
            "CMUX_SOCKET_PATH", "ZELLIJ", "ZELLIJ_PANE_ID", "VSCODE_GIT_IPC_HANDLE",
            "__CFBundleIdentifier", "TERMINAL_EMULATOR"] {
    if let val = env[key] {
        print("  \(key) = \(val)")
    }
}

print("")
print("--- 検出結果 ---")
print("  \(label("callerApp")) \(callerApp ?? "nil")  \(callerOverride != nil ? "(--caller で指定)" : "(自動検出)")")
print("  \(label("cwd"))       \(cwd ?? "nil")  \(cwdOverride != nil ? "(--cwd で指定)" : "(自動検出)")")

print("")
print("--- 戦略 ---")
print("  \(strategy)")

print("")
if dryRun {
    print("--- フォーカス (dry-run: スキップ) ---")
} else {
    print("--- フォーカス実行 ---")
    let succeeded = Foxus.execute(strategy: strategy)
    print("  結果: \(succeeded ? "✓ 成功" : "✗ 失敗")")
}
print("")
