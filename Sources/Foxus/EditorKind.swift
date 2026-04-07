import Foundation

/// エディタの種類
///
/// callerApp や FocusStrategy からエディタを判定するための型。
/// UI 表示用の Color/label は呼び出し側（アプリ層）で extension する想定。
public enum EditorKind: String, Codable {
    case vscode, cursor, jetbrains, zed, other

    /// callerApp 文字列と FocusStrategy からエディタ種別を判定
    public static func detect(callerApp: String?, strategy: FocusStrategy?) -> EditorKind {
        if let app = callerApp?.lowercased() {
            if app.contains("vscode") || app == "code" { return .vscode }
            if app.contains("cursor") { return .cursor }
            if ["idea", "intellij", "clion", "goland", "webstorm", "pycharm",
                "phpstorm", "rubymine", "rider", "datagrip", "fleet"]
                .contains(where: { app.contains($0) }) { return .jetbrains }
            if app.contains("zed") { return .zed }
        }
        if let strategy = strategy {
            switch strategy {
            case .vscode: return .vscode
            case .intellij: return .jetbrains
            default: break
            }
        }
        return .other
    }
}
