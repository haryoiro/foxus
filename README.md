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

### ターミナルマルチプレクサ

| 環境 | ウィンドウフォーカス | ペイン/タブ復元 |
|---|---|---|
| cmux | ✅ | ✅ socket API |
| tmux | ✅ | ✅ `tmux select-pane` |
| zellij | ✅ | ✅ `zellij action focus-pane-with-id` |
| WezTerm | ✅ | ✅ `wezterm cli focus-pane` |
| kitty | ✅ | ✅ `kitten @ focus-window` |

### エディタ統合ターミナル

| エディタ | ウィンドウフォーカス | ターミナルタブフォーカス | 備考 |
|---|---|---|---|
| VSCode / Cursor | ✅ IPC | ✅ AX API | settings.json の変更で精度向上（後述） |
| JetBrains IDE | ✅ AX API | ✅ ideScript | プロセスツリーからタブを特定 |
| Zed | ✅ AX API | ❌ | GPUI が Accessibility 未対応のため ([#6576](https://github.com/zed-industries/zed/discussions/6576)) |

### その他ターミナル

プロセスツリーからアプリを自動検出し、AX API でウィンドウをフォーカスします。

### VSCode ターミナルタブフォーカス

複数のターミナルタブがある場合、正しいタブまで自動フォーカスします。

タブタイトルの設定を変更するとタブ特定の精度が上がります。

```jsonc
// settings.json
{ "terminal.integrated.tabs.title": "${sequence}${separator}${process}" }
```

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
