import OSLog

// MARK: - Foxus Logging

enum Log {
    static let focus   = Logger(subsystem: "com.haryoiro.foxus", category: "focus")
    static let hooks   = Logger(subsystem: "com.haryoiro.foxus", category: "hooks")
    static let git     = Logger(subsystem: "com.haryoiro.foxus", category: "git")
    static let process = Logger(subsystem: "com.haryoiro.foxus", category: "process")
}
