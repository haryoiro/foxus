import AppKit
import Foundation

// MARK: - responsibility プライベートAPI
// libresponsibility.dylib のプライベート関数。
// あるプロセスを「責任を持つ」GUIアプリのPIDを一発で取得できる。
// プロセスツリーを遡るループが不要になるため、検出が高速かつ確実。
// macOS 内部でも広く使われており比較的安定しているが、プライベートAPIのため
// 将来のバージョンで変わる可能性はある。

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t, _ responsible: UnsafeMutablePointer<pid_t>) -> Int32

/// 親プロセスからターミナルアプリを検出
///
/// `responsibility_get_pid_responsible_for_pid` でGUIアプリを一発取得し、
/// 失敗時はプロセスツリーを遡るフォールバックを使用する。
/// 既知のアプリはTERM_PROGRAM名で返し、未知のアプリはバンドルIDをそのまま返す。
public enum ProcessDetector {

    /// バンドルID -> TERM_PROGRAM名のマッピング（既知アプリの名前解決用）
    private static var bundleIdToTermProgram: [String: String] { BundleIDRegistry.allTerminalApps }

    /// ターミナルアプリを検出
    ///
    /// - Parameter env: 環境変数辞書（デフォルト: ProcessInfo.processInfo.environment）
    /// - Returns: 既知アプリのTERM_PROGRAM名、または未知アプリのバンドルID
    public static func detectTerminalApp(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        // 1. responsibility API で一発取得（高速パス）
        if let result = detectViaResponsibility() {
            return result
        }

        // 2. プロセスツリーを遡るフォールバック
        if let result = detectViaProcessTree() {
            return result
        }

        // 3. TERM_PROGRAM環境変数をフォールバックとして使用
        let termProgram = env["TERM_PROGRAM"]

        // tmux環境の場合、クライアントPIDから実際のターミナルアプリを検出
        if termProgram == "tmux" {
            if let realTerminal = TmuxWindowDetector.detectRealTerminalApp() {
                return realTerminal
            }
        }

        // cmuxはTERM_PROGRAM=ghosttyを設定するが、CMUX_WORKSPACE_IDで区別可能
        if termProgram == "ghostty" && env["CMUX_WORKSPACE_ID"] != nil {
            return "cmux"
        }

        return termProgram
    }

    // MARK: - Private

    /// responsibility_get_pid_responsible_for_pid で責任GUIアプリを一発取得
    private static func detectViaResponsibility() -> String? {
        var responsiblePid: pid_t = 0
        let result = responsibility_get_pid_responsible_for_pid(getpid(), &responsiblePid)
        guard result == 0, responsiblePid > 1, responsiblePid != getpid() else { return nil }

        guard let bundleId = getBundleId(for: responsiblePid) else { return nil }
        return bundleIdToTermProgram[bundleId] ?? bundleId
    }

    /// プロセスツリーを最大20階層遡ってGUIアプリを検出
    private static func detectViaProcessTree() -> String? {
        var currentPid = getpid()
        var visitedPids: Set<pid_t> = []

        for _ in 0..<20 {
            guard !visitedPids.contains(currentPid) else { break }
            visitedPids.insert(currentPid)

            let parentPid = ProcessUtils.getParentPid(of: currentPid)
            guard parentPid > 1 else { break }

            if let bundleId = getBundleId(for: parentPid) {
                return bundleIdToTermProgram[bundleId] ?? bundleId
            }

            currentPid = parentPid
        }
        return nil
    }

    /// 指定PIDのバンドルIDを取得
    private static func getBundleId(for pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == pid }?.bundleIdentifier
    }
}
