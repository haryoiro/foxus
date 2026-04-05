import AppKit
import Darwin
import Foundation

/// プロセス・システムレベルのユーティリティ
///
/// pid/cwd/TTY の取得、コマンド実行など、
/// AXウィンドウ操作を含まない低レベル操作を担う。
public enum ProcessUtils {

    // MARK: - cwd 取得（libproc）

    /// 指定PIDのcwdを取得（proc_pidinfo使用）
    public static func getCwdForPid(_ pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size

        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(size))
        guard result == size else { return nil }

        let path = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { charPtr in
                String(cString: charPtr)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// 親プロセスのcwdを取得
    public static func getParentCwd() -> String? {
        getCwdForPid(getppid())
    }

    // MARK: - プロセス情報取得（sysctl）

    /// 指定PIDの親PIDを取得
    public static func getParentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// 指定PIDのTTYデバイス番号を取得
    public static func getTtyDev(of pid: pid_t) -> dev_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let ttyDev = info.kp_eproc.e_tdev
        return ttyDev == -1 ? nil : ttyDev
    }

    /// 指定TTYデバイスを使用しているシェルプロセスのPIDを取得
    public static func findShellPidByTty(_ ttyDev: dev_t) -> pid_t? {
        let shellNames = ["zsh", "bash", "fish", "sh"]
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0

        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.size
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }

        for proc in procs where proc.kp_eproc.e_tdev == ttyDev {
            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { charPtr in
                    String(cString: charPtr)
                }
            }
            if shellNames.contains(name) { return proc.kp_proc.p_pid }
        }
        return nil
    }

    // MARK: - TTY 検出

    /// 現在のTTYに紐づくシェルのcwdを取得
    public static func getCwdFromCurrentTty() -> String? {
        let ppid = getppid()
        guard let ttyDev = getTtyDev(of: ppid),
              let shellPid = findShellPidByTty(ttyDev)
        else { return nil }
        return getCwdForPid(shellPid)
    }

    /// TTYからウィンドウタイトル（ディレクトリ名）を推測
    public static func detectWindowTitleFromTty() -> String? {
        guard let cwd = getCwdFromCurrentTty() else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: - プロセス環境変数取得

    /// プロセスのPWD環境変数を取得（ps経由）
    public static func getProcessPwd(pid: pid_t) -> String? {
        let output = runCommand("/bin/ps", arguments: ["eww", "-o", "command=", "-p", "\(pid)"])
        guard let output = output else { return nil }

        // スペースまたは先頭に続くPWD=にマッチ（OLDPWDを除外）
        let pattern = "(?:^|\\s)PWD=([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output)
        else { return nil }

        return String(output[range])
    }

    // MARK: - Unixソケット検索（lsof）

    /// 指定パスを含むUnixソケットを持つプロセスのPIDを検索
    public static func findPidWithUnixSocket(containing socketPathPart: String) -> pid_t? {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-U"])
        guard let output = output else { return nil }

        for line in output.components(separatedBy: "\n") where line.contains(socketPathPart) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2, let pid = Int32(parts[1]) { return pid }
        }
        return nil
    }

    // MARK: - バイナリ検索

    /// PATH環境変数とフォールバックパスからコマンドバイナリを検索
    public static func findBinary(_ name: String, fallbacks: [String] = []) -> String? {
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - コマンド実行

    /// コマンドを実行して出力を取得
    public static func runCommand(_ path: String, arguments: [String], timeout: TimeInterval = 5.0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // 出力を非同期で収集（パイプバッファ溢れ防止）
        var outputData = Data()
        let readQueue = DispatchQueue(label: "ProcessUtils.runCommand.read")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            readQueue.sync { outputData.append(data) }
        }

        do {
            try process.run()
            process.waitUntilExit()

            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            readQueue.sync { outputData.append(remaining) }

            return String(data: outputData, encoding: .utf8)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }
}
