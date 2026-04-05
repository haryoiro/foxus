# Window Tracking

How foxus identifies the terminal app and window to focus.

---

## Flow

```
Foxus.focus(cwd:)
  ├─ ProcessDetector.detectTerminalApp()   → detect callerApp
  ├─ FocusStrategyResolver.determine()    → pick strategy
  └─ Foxus.execute(strategy:)             → run strategy
```

---

## App Detection (ProcessDetector)

### responsibility API

Uses the macOS private API `responsibility_get_pid_responsible_for_pid` to get the PID of the GUI app responsible for the current process in a single call — no process tree traversal needed.

```swift
responsibility_get_pid_responsible_for_pid(getpid(), &responsiblePid)
```

This is a private API and may change in future macOS versions.

### Process tree traversal

If the responsibility API fails, walks up the process tree via `NSWorkspace.shared.runningApplications` and `sysctl(KERN_PROC_PID)` up to 20 levels to find the first GUI app.

### TERM_PROGRAM

If process detection fails, reads the `TERM_PROGRAM` environment variable.
- `TERM_PROGRAM=tmux` → delegates to `TmuxWindowDetector.detectRealTerminalApp()`
- `TERM_PROGRAM=ghostty` + `CMUX_WORKSPACE_ID` set → returns `"cmux"`

---

## Strategy Selection (FocusStrategyResolver)

| Priority | Strategy | Condition |
|---|---|---|
| 1 | `cmux` | `CMUX_WORKSPACE_ID` is set |
| 2 | `tmux` | `TMUX` is set |
| 3 | `zellij` | `ZELLIJ` is set |
| 4 | `wezterm` | `WEZTERM_PANE` is set |
| 5 | `kitty` | `KITTY_WINDOW_ID` is set |
| 6 | `vscode` | callerApp / `TERM_PROGRAM` / `VSCODE_GIT_IPC_HANDLE` |
| 7 | `intellij` | callerApp / `__CFBundleIdentifier` / `TERMINAL_EMULATOR` etc. |
| 8 | `generic` | callerApp or cwd is available |
| 9 | `fallback` | no information |

---

## Strategy Implementations

### cmux

Sends a `surface.focus` command via Unix socket (`CMUX_SOCKET_PATH`), targeting the tab identified by `CMUX_SURFACE_ID`.

cmux sets `TERM_PROGRAM=ghostty`, so `CMUX_WORKSPACE_ID` is used to distinguish it from Ghostty.

### tmux

1. Gets client PIDs via `tmux list-clients`
2. Walks the client's process tree to find the actual GUI terminal
3. On click, restores the pane with `tmux select-window` + `tmux select-pane`

tmux binary is searched in `PATH`, then Homebrew paths, then `/usr/bin`.

### zellij

Restores the pane with `zellij action focus-pane-with-id $ZELLIJ_PANE_ID`.

### WezTerm

Restores the pane with `wezterm cli focus-pane --pane-id $WEZTERM_PANE`.
Uses `WEZTERM_UNIX_SOCKET` if available.

### kitty

Restores the window with `kitten @ focus-window --match id:<ID>`.
Requires `allow_remote_control yes` in kitty.conf.

### VSCode

Tries the following in order:

1. `VSCODE_GIT_IPC_HANDLE` → find the process holding the socket → get its PWD → match window title
2. `cwd` folder name → match window title
3. If inside a git worktree, extract parent repo name from `/.worktrees/` path → match window title
4. Detect cwd from TTY → match window title
5. Activate the VSCode app without targeting a specific window

Socket lookup uses `proc_listallpids` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`.
PWD extraction uses `sysctl(KERN_PROCARGS2)`.

### IntelliJ / JetBrains

Tries cwd folder name match → `__CFBundleIdentifier`-based project name → search across all JetBrains IDEs → activate the app.

### generic

If bundle ID is known: try cwd match, then activate the app.
If bundle ID is unknown: search all terminal apps by cwd folder name.

---

## Process Information APIs

No external commands (`ps`, `lsof`) are used.

| Purpose | API |
|---|---|
| Process cwd | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` |
| Process PWD env var | `sysctl(KERN_PROCARGS2)` |
| Find Unix socket owner | `proc_listallpids` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` |
| Parent PID / TTY device | `sysctl(KERN_PROC_PID)` |

---

## Space Movement

If the target window is on a different Space, moves it to the current Space using the CGS private API:

```swift
CGSMoveWindowsToManagedSpace(connectionID, windowArray, currentSpaceID)
```

Falls back to `app.activate()` for fullscreen Spaces.
CGS is a private API and may change in future macOS versions.

---

## Limitations

- macOS only (AppKit, Accessibility API, kernel APIs)
- VSCode, IntelliJ, and generic strategies require the project name to appear in the window title
- kitty requires `allow_remote_control yes`
- CGS Space movement is a private API and may break in future macOS versions
