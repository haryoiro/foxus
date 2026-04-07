/// フォーカス復元の共通インターフェース
public protocol FocusDetector {
    static func focusCurrentWindow(cwd: String?, env: [String: String]) -> Bool
}
