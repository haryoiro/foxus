# ウィンドウ追跡の仕様

foxus がどのようにターミナルアプリ・ウィンドウを特定してフォーカスを戻すかを説明する。

---

## 全体フロー

```
Foxus.focus(cwd:)
  ├─ ProcessDetector.detectTerminalApp()   → callerApp を検出
  ├─ FocusStrategyResolver.determine()    → 戦略を決定
  └─ Foxus.execute(strategy:)             → 戦略を実行
```

---

## アプリ検出（ProcessDetector）

### 1. responsibility API（高速パス）

macOS プライベートAPI `responsibility_get_pid_responsible_for_pid` を使い、
現在のプロセスに対して「責任を持つ」GUIアプリのPIDを一発で取得する。

```swift
responsibility_get_pid_responsible_for_pid(getpid(), &responsiblePid)
```

プロセスツリーを遡るループが不要で、確実かつ高速に検出できる。
プライベートAPIのため将来のmacOSで変わる可能性はある。

### 2. プロセスツリー探索（フォールバック）

responsibility API が失敗した場合、`NSWorkspace.shared.runningApplications` と
`sysctl(KERN_PROC_PID)` を使ってプロセスツリーを最大20階層遡り、
最初に見つかった GUI アプリを返す。

### 3. TERM_PROGRAM 環境変数（最終フォールバック）

上記が失敗した場合に `TERM_PROGRAM` 環境変数を参照する。
- `TERM_PROGRAM=tmux` → `TmuxWindowDetector.detectRealTerminalApp()` に委譲
- `TERM_PROGRAM=ghostty` かつ `CMUX_WORKSPACE_ID` あり → `"cmux"` を返す

---

## 戦略決定（FocusStrategyResolver）

検出した `callerApp` と環境変数から以下の優先順位で戦略を決定する。

| 優先度 | 戦略 | 判定条件 |
|---|---|---|
| 1 | `cmux` | `CMUX_WORKSPACE_ID` あり |
| 2 | `tmux` | `TMUX` あり |
| 3 | `zellij` | `ZELLIJ` あり |
| 4 | `wezterm` | `WEZTERM_PANE` あり |
| 5 | `kitty` | `KITTY_WINDOW_ID` あり |
| 6 | `vscode` | callerApp / `TERM_PROGRAM` / `VSCODE_GIT_IPC_HANDLE` |
| 7 | `intellij` | callerApp / `__CFBundleIdentifier` / `TERMINAL_EMULATOR` 等 |
| 8 | `generic` | callerApp or cwd がある |
| 9 | `fallback` | 情報なし |

---

## 各戦略の実装

### cmux

`CMUX_SOCKET_PATH` からUnixソケット経由で `surface.focus` コマンドを送信する。
`CMUX_SURFACE_ID` でタブを特定して復元する。

cmux は `TERM_PROGRAM=ghostty` を設定するため、
`CMUX_WORKSPACE_ID` の有無で Ghostty と区別している。

### tmux

1. `tmux list-clients` でクライアントPIDを取得
2. クライアントPIDのプロセスツリーから実際のGUIターミナルを特定
3. クリック時に `tmux select-window` + `tmux select-pane` でペインを復元

tmux バイナリは `PATH` → Homebrew → `/usr/bin` の順に検索する。

### zellij

`ZELLIJ_PANE_ID` を使い `zellij action focus-pane-with-id` でペインを復元する。

### WezTerm

`WEZTERM_PANE` を使い `wezterm cli focus-pane --pane-id` でペインを復元する。
`WEZTERM_UNIX_SOCKET` があればそのソケットを明示的に指定する。

### kitty

`KITTY_WINDOW_ID` を使い `kitten @ focus-window --match id:<ID>` でウィンドウを復元する。
kitty 側で `allow_remote_control yes` の設定が必要。

### VSCode

以下の優先順位でウィンドウを特定する:

1. `VSCODE_GIT_IPC_HANDLE` → ソケットを保持するプロセスの PWD を取得 → プロジェクト名マッチ
2. `cwd` のフォルダ名でウィンドウタイトルをマッチ
3. git worktree の場合、`/.worktrees/` より前の親リポジトリ名でマッチ
4. TTY からシェルの cwd を推測してマッチ
5. フォールバック: アプリ全体をアクティブ化

ソケット保持プロセスの特定に `proc_listallpids` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` を使用する（`lsof` 不使用）。
プロセスの PWD 取得に `sysctl(KERN_PROCARGS2)` を使用する（`ps` 不使用）。

### IntelliJ / JetBrains

cwd のフォルダ名 → `__CFBundleIdentifier` からのプロジェクト名 → 全IDE検索 → フォールバックの順で試みる。

### generic

バンドルIDが分かっている場合は cwd マッチ → アプリ全体アクティブ化。
バンドルIDが不明な場合は cwd のフォルダ名で全ターミナルアプリを検索する。

---

## プロセス情報の取得

外部コマンド（`ps`・`lsof`）は使用しない。すべてカーネルAPIで処理する。

| 用途 | API |
|---|---|
| プロセスの cwd 取得 | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` |
| プロセスの PWD 環境変数取得 | `sysctl(KERN_PROCARGS2)` |
| Unix ソケット保持プロセスの検索 | `proc_listallpids` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` |
| 親PID・TTYデバイス番号取得 | `sysctl(KERN_PROC_PID)` |

---

## Space 移動

ターゲットウィンドウが別の Space にある場合、CGS プライベートAPIでウィンドウを現在の Space に移動する。

```swift
CGSMoveWindowsToManagedSpace(connectionID, windowArray, currentSpaceID)
```

フルスクリーン Space の場合は `app.activate()` にフォールバックする。
CGS はプライベートAPIのため、将来の macOS で動作しなくなる可能性がある。

---

## 制限事項

- macOS 専用（AppKit・Accessibility API・カーネルAPIに依存）
- ウィンドウタイトルにプロジェクト名が含まれている必要がある（VSCode・IntelliJ・generic）
- kitty は `allow_remote_control yes` の設定が必要
- CGS Space 移動はプライベートAPIのため将来変わる可能性がある
