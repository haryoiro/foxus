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

    // MARK: - プロセス環境変数取得（sysctl KERN_PROCARGS2）

    /// プロセスのPWD環境変数を取得
    ///
    /// `sysctl(KERN_PROCARGS2)` でカーネルバッファを直接読み取る（ps より約23倍高速）。
    ///
    /// バッファレイアウト:
    ///   [0..3] argc (Int32 LE)
    ///   [4..]  exec_path (NUL終端) + NULパディング + argv[0..argc-1] + env[0..]
    public static func getProcessPwd(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // 先頭4バイト = argc (リトルエンディアン)
        let argc = Int(buffer[0])
            | (Int(buffer[1]) << 8)
            | (Int(buffer[2]) << 16)
            | (Int(buffer[3]) << 24)

        // exec_path をスキップ
        var offset = 4
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // NULパディングをスキップ（ポインタアラインメント用）
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // argv[0..argc-1] をスキップ
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            offset += 1
        }

        // 環境変数を走査して PWD= を探す
        while offset < size {
            var end = offset
            while end < size && buffer[end] != 0 { end += 1 }
            guard end > offset else { break }  // 空文字列 = 終端

            if let envStr = String(bytes: buffer[offset..<end], encoding: .utf8),
               envStr.hasPrefix("PWD=") {
                return String(envStr.dropFirst(4))
            }
            offset = end + 1
        }
        return nil
    }

    // MARK: - Unixソケット検索（proc_listallpids + proc_pidfdinfo）

    /// 指定パスを含むUnixソケットを持つプロセスのPIDを検索
    ///
    /// `proc_listallpids` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` を使用。
    /// lsof より約250〜450倍高速（外部プロセス起動なし）。
    public static func findPidWithUnixSocket(containing socketPathPart: String) -> pid_t? {
        // 全PIDを取得
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return nil }

        // バッファに余裕を持たせる（列挙中に増減しうるため）
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 32)
        let actualCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard actualCount > 0 else { return nil }

        for pid in pids.prefix(Int(actualCount)) where pid > 0 {
            if let found = checkPidForUnixSocket(pid: pid, containing: socketPathPart) {
                return found
            }
        }
        return nil
    }

    // MARK: - Private

    /// 1プロセスのfdを検査してUnixソケットパスを照合
    private static func checkPidForUnixSocket(pid: pid_t, containing socketPathPart: String) -> pid_t? {
        let fdBufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdBufSize > 0 else { return nil }

        let fdCount = Int(fdBufSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let actualFdSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBufSize)
        guard actualFdSize > 0 else { return nil }

        let actualFdCount = Int(actualFdSize) / MemoryLayout<proc_fdinfo>.size
        for fd in fds.prefix(actualFdCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var sockInfo = socket_fdinfo()
            let ret = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO,
                                     &sockInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            guard ret == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            guard sockInfo.psi.soi_family == AF_UNIX else { continue }

            // sun_path はCCharタプル — rawポインタ経由で文字列化
            let path = withUnsafePointer(to: sockInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) {
                    String(cString: $0)
                }
            }
            if path.contains(socketPathPart) { return pid }
        }
        return nil
    }

    // MARK: - 祖先プロセス情報

    /// 祖先プロセスを辿り、TTYを持つ最初のプロセスの `p_comm` を返す。
    ///
    /// VSCode統合ターミナルでは、フォアグラウンドプロセスの `p_comm` が
    /// タブタイトルの `${process}` に使われる。
    /// Claude Code の場合 `"2.1.92"` のようなバージョン文字列が返る。
    public static func getAncestorPComm() -> String? {
        var pid = getpid()
        for _ in 0..<10 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { break }

            if info.kp_eproc.e_tdev != -1 {
                let name = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { charPtr in
                        String(cString: charPtr)
                    }
                }
                return name.isEmpty ? nil : name
            }

            let ppid = info.kp_eproc.e_ppid
            if ppid <= 1 { break }
            pid = ppid
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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 出力を非同期で収集（パイプバッファ溢れ防止）
        var outputData = Data()
        var errorData = Data()
        let readQueue = DispatchQueue(label: "ProcessUtils.runCommand.read")
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            readQueue.sync { outputData.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            readQueue.sync { errorData.append(data) }
        }

        do {
            try process.run()
            process.waitUntilExit()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readQueue.sync {
                outputData.append(remaining)
                errorData.append(remainingErr)
            }

            if process.terminationStatus != 0,
               let stderrStr = String(data: errorData, encoding: .utf8),
               !stderrStr.isEmpty {
                Log.focus.warning("runCommand: \(path, privacy: .public) exited with \(process.terminationStatus): \(stderrStr, privacy: .public)")
            }

            return String(data: outputData, encoding: .utf8)
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Log.focus.error("runCommand: \(path, privacy: .public) 起動失敗: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
