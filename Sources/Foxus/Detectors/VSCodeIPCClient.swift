import Darwin
import Foundation

/// VSCode メインプロセスの IPC ソケットと通信するクライアント。
///
/// VSCode は起動時に Unix ドメインソケット（`{userDataPath}/{version[:4]}-main.sock`）を
/// 作成し、ウィンドウ情報の取得やウィンドウフォーカスのリクエストを受け付ける。
///
/// ## プロトコル仕様
/// - **外側フレーム**: 13バイトヘッダー `[type:1][id:4BE][ack:4BE][dataLen:4BE]` + payload
/// - **内側ペイロード**: VSBuffer ベースのコンパクトシリアライゼーション
///   - `0x00` = Undefined/null
///   - `0x01` + LEB128(len) + utf8bytes = String
///   - `0x04` + LEB128(count) + items = Array
///   - `0x05` + LEB128(len) + jsonBytes = Object (JSON)
///   - `0x06` + LEB128(value) = UInt
/// - **ハンドシェイク**: クライアントが `"cli"` を送信 → サーバーが `[200]` を返す
/// - **チャネル呼び出し**: `[100, callId, channelName, methodName]` + arg を送信
///   → サーバーが `[201, callId]` + result を返す（同一フレーム内）
///
/// ## 利用可能なチャネル
/// - `diagnostics.getMainDiagnostics()`: 全ウィンドウの folderURIs・PID・タイトルを返す
/// - `launch.start(args, userEnv)`: 指定パスのウィンドウをフォーカス（`app.focus({steal:true})` 相当）
public enum VSCodeIPCClient {

    // MARK: - 公開API

    /// `diagnostics.getMainDiagnostics()` の結果
    public struct DiagnosticsResult {
        public let windows: [WindowInfo]
    }

    /// ウィンドウ情報（getMainDiagnostics の windows 配列の各要素）
    public struct WindowInfo {
        public let id: Int
        public let pid: Int
        public let title: String
        /// このウィンドウで開いているフォルダのパス一覧
        public let folderPaths: [String]
    }

    /// VSCode の全ウィンドウ情報を取得する。
    public static func getMainDiagnostics(socketPath: String) -> DiagnosticsResult? {
        guard let body = callIPC(socketPath: socketPath, channel: "diagnostics", method: "getMainDiagnostics", arg: nil),
              let dict = body as? [String: Any],
              let windows = dict["windows"] as? [[String: Any]]
        else { return nil }

        let windowInfos = windows.compactMap { w -> WindowInfo? in
            guard let id = w["id"] as? Int,
                  let pid = w["pid"] as? Int
            else { return nil }
            let title = w["title"] as? String ?? ""
            var folderPaths: [String] = []
            if let uris = w["folderURIs"] as? [[String: Any]] {
                for uri in uris {
                    if let path = uri["path"] as? String, !path.isEmpty {
                        folderPaths.append(path)
                    }
                }
            }
            return WindowInfo(id: id, pid: pid, title: title, folderPaths: folderPaths)
        }
        return DiagnosticsResult(windows: windowInfos)
    }

    /// `launch.start()` で指定フォルダパスのウィンドウをフォーカスする。
    ///
    /// VSCode 内部で `app.focus({steal: true})` が呼ばれるため、
    /// 別のSpaceにあるウィンドウも現在のSpaceに引き寄せてフォーカスする。
    ///
    /// - Parameter folderPath: フォーカスしたいワークスペースの絶対パス（`/path/to/project` 形式）
    /// - Parameter socketPath: VSCode main IPC ソケットのパス
    /// - Returns: IPC 通信に成功した場合は true
    @discardableResult
    public static func focusWindow(folderPath: String, socketPath: String) -> Bool {
        let folderURI = "file://\(folderPath)"
        // launch.start() の引数は [cliArgs, userEnv] の配列
        let cliArgs: [String: Any] = [
            "_": [String](),
            "folder-uri": [folderURI],
            "reuse-window": true,
            "open-url": false,
            "_urls": [String]()
        ]
        let arg: [Any] = [cliArgs, [String: Any]()]

        // callIPC が Optional.none = 通信失敗
        // callIPC が Optional.some(_) = IPC 呼び出し成功（launch.start の result は nil）
        let ipcResult = callIPC(socketPath: socketPath, channel: "launch", method: "start", arg: arg)
        return ipcResult != nil  // .some(nil) でも true = 通信成功
    }

    // MARK: - ソケットパス探索

    /// VSCode 系アプリの main IPC ソケットパスをすべて探す。
    ///
    /// 各アプリのユーザーデータディレクトリを走査し、`*-main.sock` ファイルを返す。
    public static func findSocketPaths() -> [(bundleId: String, socketPath: String)] {
        // bundleId → userDataPath のマッピング
        let candidates: [(bundleId: String, path: String)] = [
            ("com.microsoft.VSCode",         "~/Library/Application Support/Code"),
            ("com.microsoft.VSCodeInsiders",  "~/Library/Application Support/Code - Insiders"),
            ("com.todesktop.230313mzl4w4u92", "~/Library/Application Support/Cursor"),
            ("com.vscodium",                  "~/Library/Application Support/VSCodium"),
        ]

        var results: [(bundleId: String, socketPath: String)] = []
        let fm = FileManager.default

        for entry in candidates {
            let expandedPath = (entry.path as NSString).expandingTildeInPath
            guard let files = try? fm.contentsOfDirectory(atPath: expandedPath) else { continue }
            for file in files where file.hasSuffix("-main.sock") {
                let fullPath = "\(expandedPath)/\(file)"
                results.append((bundleId: entry.bundleId, socketPath: fullPath))
            }
        }
        return results
    }

    // MARK: - 低レベルIPC

    /// IPC チャネルを呼び出して結果を返す。
    ///
    /// - Returns: デシリアライズされた結果（null 結果は nil as Any?）。通信失敗時は Optional.none。
    ///   戻り値が Optional.none か `.some(nil)` かで通信成否を区別できる。
    static func callIPC(socketPath: String, channel: String, method: String, arg: Any?) -> Any?? {
        let sockFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else { return nil }
        defer { Darwin.close(sockFd) }

        // タイムアウト設定（500ms）
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sockFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // ソケット接続
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cStr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) {
                    strcpy($0, cStr)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sockFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Log.focus.debug("VSCodeIPC: connect failed \(socketPath, privacy: .public)")
            return nil
        }

        // ハンドシェイク: "cli" を送信 → [200] を受信
        guard sendFrame(sockFd, payload: serializeString("cli")),
              receiveFrame(sockFd) != nil
        else { return nil }

        // チャネル呼び出し: [100, callId, channel, method] + arg
        let callPayload = serializeArray([
            serializeUInt(100),
            serializeUInt(1),
            serializeString(channel),
            serializeString(method),
        ]) + serializeValue(arg)
        guard sendFrame(sockFd, payload: callPayload) else { return nil }

        // レスポンスフレーム受信
        guard let responseData = receiveFrame(sockFd) else { return nil }

        // [201, callId] ヘッダー + result をデコード
        var pos = responseData.startIndex
        guard let rawHeader = deserializeValue(responseData, pos: &pos),
              let header = rawHeader as? [Any],
              header.count >= 2,
              (header[0] as? Int) == 201
        else { return nil }

        let result = deserializeValue(responseData, pos: &pos)
        return .some(result)
    }

    // MARK: - シリアライゼーション（VSBuffer プロトコル）

    /// LEB128 エンコード
    private static func leb128(_ n: Int) -> Data {
        if n == 0 { return Data([0]) }
        var value = n
        var bytes = [UInt8]()
        while value != 0 {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            bytes.append(b)
        }
        return Data(bytes)
    }

    static func serializeString(_ s: String) -> Data {
        let utf8 = s.data(using: .utf8) ?? Data()
        return Data([0x01]) + leb128(utf8.count) + utf8
    }

    static func serializeUInt(_ n: Int) -> Data {
        return Data([0x06]) + leb128(n)
    }

    static func serializeNull() -> Data { Data([0x00]) }

    static func serializeArray(_ items: [Data]) -> Data {
        var result = Data([0x04]) + leb128(items.count)
        for item in items { result.append(item) }
        return result
    }

    private static func serializeObject(_ obj: Any) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: obj) else {
            return serializeNull()
        }
        return Data([0x05]) + leb128(json.count) + json
    }

    static func serializeValue(_ value: Any?) -> Data {
        guard let value = value else { return serializeNull() }
        switch value {
        case let s as String: return serializeString(s)
        case let n as Int:    return serializeUInt(n)
        case let b as Bool:   return serializeUInt(b ? 1 : 0)
        case let arr as [Data]:
            // 既にシリアライズ済みの Data 配列
            return serializeArray(arr)
        case let arr as [Any]:
            // 混合型配列
            if JSONSerialization.isValidJSONObject(arr) {
                return serializeObject(arr)
            }
            return serializeArray(arr.map { serializeValue($0) })
        case let dict as [String: Any]:
            return serializeObject(dict)
        default:
            if JSONSerialization.isValidJSONObject(value) {
                return serializeObject(value)
            }
            return serializeNull()
        }
    }

    // MARK: - デシリアライゼーション

    private static func decodeLEB128(_ data: Data, pos: inout Data.Index) -> Int {
        var n = 0; var shift = 0
        while pos < data.endIndex {
            let b = Int(data[pos]); pos = data.index(after: pos)
            n |= (b & 0x7F) << shift; shift += 7
            if b & 0x80 == 0 { break }
        }
        return n
    }

    static func deserializeValue(_ data: Data, pos: inout Data.Index) -> Any? {
        guard pos < data.endIndex else { return nil }
        let typ = data[pos]; pos = data.index(after: pos)
        switch typ {
        case 0x00:
            return nil
        case 0x01:  // String
            let len = decodeLEB128(data, pos: &pos)
            let end = data.index(pos, offsetBy: len, limitedBy: data.endIndex) ?? data.endIndex
            let str = String(data: data[pos..<end], encoding: .utf8) ?? ""
            pos = end
            return str
        case 0x04:  // Array
            let count = decodeLEB128(data, pos: &pos)
            var items = [Any]()
            for _ in 0..<count {
                items.append(deserializeValue(data, pos: &pos) as Any)
            }
            return items
        case 0x05:  // Object (JSON)
            let len = decodeLEB128(data, pos: &pos)
            let end = data.index(pos, offsetBy: len, limitedBy: data.endIndex) ?? data.endIndex
            let jsonData = data[pos..<end]; pos = end
            return (try? JSONSerialization.jsonObject(with: jsonData)) as Any?
        case 0x06:  // UInt (LEB128)
            return decodeLEB128(data, pos: &pos)
        default:
            Log.focus.warning("VSCodeIPC: unknown type byte \(typ, privacy: .public)")
            return nil
        }
    }

    // MARK: - フレーム送受信（13バイトヘッダー）

    private static func sendFrame(_ fd: Int32, payload: Data) -> Bool {
        var header = Data(count: 13)
        header[0] = 1  // type = String（ペイロードはすべて String 型フレームで送受信）
        // bytes 1-8 は id=0, ack=0（ゼロ初期化済み）
        let len = UInt32(payload.count)
        header[9]  = UInt8((len >> 24) & 0xFF)
        header[10] = UInt8((len >> 16) & 0xFF)
        header[11] = UInt8((len >>  8) & 0xFF)
        header[12] = UInt8((len      ) & 0xFF)
        let frame = header + payload
        return frame.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, frame.count) == frame.count
        }
    }

    private static func receiveFrame(_ fd: Int32) -> Data? {
        var headerBuf = [UInt8](repeating: 0, count: 13)
        guard readExact(fd, &headerBuf, 13) == 13 else { return nil }

        let dataLen = Int(headerBuf[9])  << 24
                    | Int(headerBuf[10]) << 16
                    | Int(headerBuf[11]) << 8
                    | Int(headerBuf[12])
        guard dataLen >= 0, dataLen < 10_000_000 else { return nil }
        if dataLen == 0 { return Data() }

        var payloadBuf = [UInt8](repeating: 0, count: dataLen)
        guard readExact(fd, &payloadBuf, dataLen) == dataLen else { return nil }
        return Data(payloadBuf)
    }

    private static func readExact(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.read(fd, buf + totalRead, count - totalRead)
            if n <= 0 { return totalRead }
            totalRead += n
        }
        return totalRead
    }
}
