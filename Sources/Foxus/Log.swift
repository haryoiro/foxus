import OSLog

// MARK: - Foxus Logging

/// ウィンドウ検出・フォーカス操作のログ
///
/// Console.app または以下のコマンドで確認できる:
///   log stream --predicate 'subsystem == "com.haryoiro.foxus"' --level debug
enum Log {
    static let focus = Logger(subsystem: "com.haryoiro.foxus", category: "focus")
}
