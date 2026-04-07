import Foundation

/// バイナリパスを一元管理するユーティリティ
///
/// 各 Detector が個別に持っていたフォールバックパスを集約し、
/// 重複を排除して管理を容易にする。
public enum BinaryPaths {

    public static func tmux() -> String? {
        ProcessUtils.findBinary("tmux", fallbacks: [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ])
    }

    public static func zellij() -> String? {
        ProcessUtils.findBinary("zellij", fallbacks: [
            "/opt/homebrew/bin/zellij",
            "/usr/local/bin/zellij",
        ])
    }

    public static func wezterm() -> String? {
        ProcessUtils.findBinary("wezterm", fallbacks: [
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
        ])
    }

    public static func kitty() -> String? {
        ProcessUtils.findBinary("kitten", fallbacks: [
            "/opt/homebrew/bin/kitten",
            "/usr/local/bin/kitten",
            "/Applications/kitty.app/Contents/MacOS/kitten",
        ])
    }

    public static func nvim() -> String? {
        ProcessUtils.findBinary("nvim", fallbacks: [
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/usr/bin/nvim",
        ])
    }
}
