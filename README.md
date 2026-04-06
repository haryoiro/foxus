# foxus

macOS でターミナル・エディタのウィンドウを特定してフォーカスを戻す Swift ライブラリ。

tmux / zellij / wezterm / kitty などのマルチプレクサのペイン復元にも対応。

## インストール

```swift
// Package.swift
.package(url: "https://github.com/haryoiro/foxus", from: "x.x.x")
```

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
| VSCode / Cursor | `$VSCODE_GIT_IPC_HANDLE` など | IPC + AX API（※） |
| JetBrains IDE | `$TERMINAL_EMULATOR` など | AX API |
| その他ターミナル | プロセスツリー自動検出 | AX API |

### VSCode ターミナルタブフォーカス

VSCode で複数のターミナルタブを開いている場合、foxus はウィンドウだけでなく正しいターミナルタブまでフォーカスを試みます。

この機能はフォアグラウンドプロセスの名前（`p_comm`）でタブを特定します。Claude Code のようにユニークなプロセス名を持つアプリケーションから呼ばれた場合は高い精度で動作しますが、素の `zsh` / `bash` が複数ある場合は区別できないためスキップされます。

精度を上げるには、VSCode の `settings.json` に以下を追加してください:

```jsonc
{
  "terminal.integrated.tabs.title": "${sequence}${separator}${process}"
}
```

この設定により、アプリケーションが設定したターミナルタイトル（`${sequence}`）がタブ名に反映され、タブの一意特定が容易になります。設定がなくてもウィンドウレベルのフォーカスは従来通り動作します。

## strategy を明示する

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
