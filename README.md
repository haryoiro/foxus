# foxus

macOS でターミナル・エディタのウィンドウを特定してフォーカスを戻すSwiftライブラリ。

tmux / zellij / wezterm / kitty などのターミナルマルチプレクサのペイン復元にも対応。

## 使い方

```swift
import Foxus

// 全自動（callerApp・cwd を自動検出）
Foxus.focus()

// cwd だけ指定（hooks JSON から渡す場合など）
Foxus.focus(cwd: "/path/to/project")

// 結果を受け取る
let result = Foxus.focus(cwd: config.cwd)
if !result.succeeded {
    // 独自フォールバック処理
}
```

## 対応環境

| 環境 | 検出方法 | ペイン/タブ復元 |
|---|---|---|
| cmux | `$CMUX_WORKSPACE_ID` | socket API |
| tmux | `$TMUX` | `tmux select-pane` |
| zellij | `$ZELLIJ` | `zellij action focus-pane-with-id` |
| WezTerm | `$WEZTERM_PANE` | `wezterm cli focus-pane` |
| kitty | `$KITTY_WINDOW_ID` | `kitten @ focus-window` |
| VSCode / Cursor | `$VSCODE_GIT_IPC_HANDLE` など | AX API |
| JetBrains IDE | `$TERMINAL_EMULATOR` など | AX API |
| その他ターミナル | プロセスツリー自動検出 | AX API |

## インストール

```swift
// Package.swift
.package(url: "https://github.com/haryoiro/foxus", from: "0.0.4")
```

## 戦略を明示する

`FocusStrategyResolver` で戦略を自分で決めてから実行することもできる:

```swift
let strategy = FocusStrategyResolver.determine(
    callerApp: "ghostty",
    cwd: "/path/to/project",
    env: ProcessInfo.processInfo.environment
)
Foxus.execute(strategy: strategy)
```

## デバッグ

```bash
# 現在の環境でどの strategy が選ばれるか確認
swift run foxus-debug --dry-run

# 実際にフォーカスを実行
swift run foxus-debug
```
