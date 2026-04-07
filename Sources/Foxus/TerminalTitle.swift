import AppKit
import ApplicationServices
import Darwin
import Foundation

/// ターミナルウィンドウタイトルを取得する。
///
/// 取得戦略（優先順）:
/// 1. cmux環境: ソケットAPI経由で workspace title を取得
/// 2. VSCode統合ターミナル: IPC経由でワークスペース名を取得
/// 3. TTY: ESC[21t でターミナルに問い合わせ（タブ固有）
/// 4. Ghostty AX API: フォーカスウィンドウのタイトル（フォールバック）
public enum TerminalTitle {

    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String? = nil
    ) -> String? {
        if let title = readFromCmux(env: env) { return title }
        if let title = readFromVSCode(env: env, cwd: cwd) { return title }
        if let title = readFromTTY() { return title }
        if let title = readFromGhostty(env: env) { return title }
        return nil
    }

    // MARK: - cmux

    private static func readFromCmux(env: [String: String]) -> String? {
        guard let surfaceId = env["CMUX_SURFACE_ID"],
              let socketPath = env["CMUX_SOCKET_PATH"] else { return nil }

        // Step 1: surface_id → workspace_id
        let surfacePayload: [String: Any] = [
            "id": "notilis-surface",
            "method": "surface.current",
            "params": ["surface_id": surfaceId]
        ]
        guard let surfaceData = try? JSONSerialization.data(withJSONObject: surfacePayload),
              let surfaceMsg = String(data: surfaceData, encoding: .utf8),
              let resp1 = sendAndReceive(socketPath: socketPath, message: surfaceMsg + "\n"),
              let r1 = try? JSONSerialization.jsonObject(with: resp1) as? [String: Any],
              let result1 = r1["result"] as? [String: Any],
              let workspaceId = result1["workspace_id"] as? String else { return nil }

        // Step 2: workspace_id → title
        let listPayload: [String: Any] = ["id": "notilis-wslist", "method": "workspace.list", "params": [:]]
        guard let listData = try? JSONSerialization.data(withJSONObject: listPayload),
              let listMsg = String(data: listData, encoding: .utf8),
              let resp2 = sendAndReceive(socketPath: socketPath, message: listMsg + "\n"),
              let r2 = try? JSONSerialization.jsonObject(with: resp2) as? [String: Any],
              let result2 = r2["result"] as? [String: Any],
              let workspaces = result2["workspaces"] as? [[String: Any]],
              let ws = workspaces.first(where: { ($0["id"] as? String) == workspaceId }),
              let rawTitle = ws["title"] as? String else { return nil }

        let stripped = rawTitle.drop(while: { !$0.isLetter && !$0.isNumber })
        return stripped.isEmpty ? nil : String(stripped)
    }

    // MARK: - VSCode

    private static func readFromVSCode(env: [String: String], cwd: String?) -> String? {
        guard env["VSCODE_GIT_IPC_HANDLE"] != nil
           || env["TERM_PROGRAM"]?.lowercased().contains("vscode") == true
        else { return nil }

        let socketPaths = VSCodeIPCClient.findSocketPaths()
        for entry in socketPaths {
            guard let diagnostics = VSCodeIPCClient.getMainDiagnostics(socketPath: entry.socketPath) else { continue }

            let window: VSCodeIPCClient.WindowInfo?
            if let cwd = cwd {
                window = diagnostics.windows.first { w in
                    w.folderPaths.contains { fp in fp == cwd || cwd.hasPrefix(fp + "/") }
                }
            } else {
                window = diagnostics.windows.first
            }

            guard let w = window, let folderPath = w.folderPaths.first else { continue }
            return (folderPath as NSString).lastPathComponent
        }
        return nil
    }

    // MARK: - Ghostty (AX API fallback)

    private static func readFromGhostty(env: [String: String]) -> String? {
        guard env["TERM_PROGRAM"] == "ghostty" || env["GHOSTTY_RESOURCES_DIR"] != nil else {
            return nil
        }
        return GhosttyWindowDetector.windowTitle()
    }

    // MARK: - TTY Query

    static func readFromTTY() -> String? {
        guard let ttyPath = findParentTTY() else { return nil }
        return queryTitle(ttyPath: ttyPath)
    }

    private static func findParentTTY() -> String? {
        var pid = getpid()
        for _ in 0..<10 {
            if let path = ttyPath(for: pid) {
                return path
            }
            let parent = parentPid(of: pid)
            guard parent > 1 else { break }
            pid = parent
        }
        return nil
    }

    private static func ttyPath(for pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }

        let tdev = info.e_tdev
        guard tdev != 0, tdev != UInt32.max else { return nil }

        let minor = Int(tdev & 0x000fffff)
        let path = "/dev/ttys\(String(format: "%03d", minor))"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                               Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return -1 }
        return pid_t(info.pbi_ppid)
    }

    private static func queryTitle(ttyPath: String) -> String? {
        let ttyFd = open(ttyPath, O_RDWR | O_NOCTTY)
        guard ttyFd >= 0 else { return nil }
        defer { close(ttyFd) }

        var saved = termios()
        guard tcgetattr(ttyFd, &saved) == 0 else { return nil }
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(ttyFd, TCSANOW, &raw)
        defer { tcsetattr(ttyFd, TCSANOW, &saved) }

        let query = "\u{1b}[21t"
        guard Darwin.write(ttyFd, query, query.utf8.count) > 0 else { return nil }

        var response = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1)
        let deadline = Date().addingTimeInterval(0.3)

        while Date() < deadline {
            var fds = fd_set()
            fdSet(ttyFd, &fds)
            var tv = timeval(tv_sec: 0, tv_usec: 20_000)
            guard select(ttyFd + 1, &fds, nil, nil, &tv) > 0 else { continue }
            guard Darwin.read(ttyFd, &buf, 1) == 1 else { break }
            response.append(buf[0])
            if buf[0] == UInt8(ascii: "~") { break }
        }

        return parseTitle(response)
    }

    private static func parseTitle(_ bytes: [UInt8]) -> String? {
        guard let raw = String(bytes: bytes, encoding: .utf8) else { return nil }
        let pattern = "\u{1b}\\[21;(.+)~"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        let title = String(raw[range])
        return title.isEmpty ? nil : title
    }

    // MARK: - Socket Communication

    private static func sendAndReceive(socketPath: String, message: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { return nil }

        _ = socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    strncpy($0, cstr, capacity)
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        message.withCString { _ = send(fd, $0, strlen($0), 0) }

        var result = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(0.5)

        while Date() < deadline {
            var fds = fd_set()
            fdSet(fd, &fds)
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            guard select(fd + 1, &fds, nil, nil, &tv) > 0 else { continue }
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else { break }
            result.append(buf, count: n)
            if buf[n - 1] == UInt8(ascii: "\n") { break }
        }

        return result.isEmpty ? nil : result
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd) / 32
        let bitOffset = Int(fd) % 32
        withUnsafeMutableBytes(of: &set) { ptr in
            ptr.bindMemory(to: Int32.self)[intOffset] |= Int32(1 << bitOffset)
        }
    }
}
