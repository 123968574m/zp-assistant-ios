import Foundation
import SocketIO

/// 云端中继上的在线设备
struct RelayHost: Identifiable, Equatable {
    let id: String
    let name: String
}

/// 与桌面端「手机互联」Socket.IO 服务的连接与状态。
/// 协议与手机网页版一致：
///   下行: response_mode / current_model / feature_sync / ai_thinking
///         answer_stream_chunk / answer_clear / answer_resync
///   上行: remote_action { action } / answer_resync
final class SessionStore: ObservableObject {
    enum ConnState: String {
        case disconnected = "未连接"
        case connecting = "连接中…"
        case connected = "已连接"
        case failed = "连接失败"
    }

    struct FeatureFlags {
        var screenshot = true
        var switchMode = true
        var scrollCtrl = true
        var clearText = true
        var voice = true
        var stopGeneration = true

        static func from(_ dict: [String: Any]) -> FeatureFlags {
            var f = FeatureFlags()
            f.screenshot = dict["screenshot"] as? Bool ?? true
            f.switchMode = dict["switchMode"] as? Bool ?? true
            f.scrollCtrl = dict["scrollCtrl"] as? Bool ?? true
            f.clearText = dict["clearText"] as? Bool ?? true
            f.voice = dict["voice"] as? Bool ?? true
            f.stopGeneration = dict["stopGeneration"] as? Bool ?? true
            return f
        }
    }

    @Published var connState: ConnState = .disconnected
    @Published var modeLabel: String = ""
    @Published var modelLabel: String = ""
    @Published var thinking: Bool = false
    @Published var answerText: String = ""
    @Published var features = FeatureFlags()
    @Published var hosts: [RelayHost] = []
    @Published var bindError: String = ""

    enum Mode { case lan, cloud }
    private var mode: Mode = .lan

    /// 连接断开/失败时的回调（悬浮控制器用来关闭小窗）
    var onDisconnected: (() -> Void)?
    /// 局域网健康检查地址（悬浮模式轮询用）
    private(set) var lanHealthURL: URL?
    var isLanMode: Bool { mode == .lan }

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var lastSeq = 0

    var isConnected: Bool { connState == .connected }

    func connect(host: String, port: String, room: String, password: String) {
        disconnect()
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.hasPrefix("http://") {
            cleanHost = String(cleanHost.dropFirst("http://".count))
        } else if cleanHost.hasPrefix("https://") {
            cleanHost = String(cleanHost.dropFirst("https://".count))
        }
        cleanHost = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanHost.isEmpty, let url = URL(string: "http://\(cleanHost):\(port)") else {
            DispatchQueue.main.async { self.connState = .failed }
            return
        }
        lastSeq = 0
        lanHealthURL = URL(string: "http://\(cleanHost):\(port)/__health")
        var params: [String: String] = ["room": room.trimmingCharacters(in: .whitespaces)]
        let pwd = password.trimmingCharacters(in: .whitespaces)
        if !pwd.isEmpty { params["password"] = pwd }
        let mgr = SocketManager(socketURL: url, config: [
            .connectParams(params),
            .reconnects(true),
            .reconnectWait(2),
            .reconnectWaitMax(15),
            .log(false)
        ])
        manager = mgr
        let sk = mgr.defaultSocket
        socket = sk
        bind(sk)
        DispatchQueue.main.async { self.connState = .connecting }
        sk.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket?.removeAllHandlers()
        socket = nil
        manager = nil
        lanHealthURL = nil
        DispatchQueue.main.async {
            self.connState = .disconnected
            self.answerText = ""
            self.thinking = false
            self.hosts = []
            self.bindError = ""
            self.onDisconnected?()
        }
    }

    /// 云端中继（非局域网）：连 navway.cc.cd 的 /phone 命名空间
    func connectCloud() {
        disconnect()
        mode = .cloud
        guard let url = URL(string: "https://navway.cc.cd") else {
            DispatchQueue.main.async { self.connState = .failed }
            return
        }
        lastSeq = 0
        lanHealthURL = nil
        let mgr = SocketManager(socketURL: url, config: [.log(false), .compress])
        manager = mgr
        let sk = mgr.socket(forNamespace: "/phone")
        socket = sk
        bind(sk)
        setMain(.connecting) { self.connState = $0 }
        PiPDebug.log("云端：连接 navway.cc.cd/phone …")
        sk.connect()
    }

    /// 配对云端设备（6 位访问码）
    func bindHost(hostId: String, code: String) {
        setMain("") { self.bindError = $0 }
        socket?.emit("bind", ["hostId": hostId, "code": code])
    }

    func send(action: String) {
        socket?.emit("remote_action", ["action": action])
    }

    private func bind(_ sk: SocketIOClient) {
        sk.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            self.lastSeq = 0
            if self.mode == .lan {
                self.setMain(.connected) { self.connState = $0 }
                // 连上后向桌面端要一次当前回答全文，补齐掉线窗口内丢失的分片
                sk.emit("answer_resync")
            } else {
                PiPDebug.log("云端：/phone 已连接，等待设备列表")
            }
            // 云端模式在 bound 之后才算连上
        }
        sk.on(clientEvent: .disconnect) { [weak self] data, _ in
            // 任何断开（对端关闭/网络掉线/主动断开）都按"已断开"处理，
            // 并通知悬浮控制器关闭小窗；socket.io 自身仍会尝试重连
            let reason = data.first as? String ?? ""
            PiPDebug.log("socket 断开：\(reason)")
            self?.setMain(.disconnected) { self?.connState = $0 }
            self?.onDisconnected?()
        }
        sk.on(clientEvent: .error) { [weak self] data, _ in
            let msg = data.first as? String ?? "unknown"
            PiPDebug.log("socket 错误：\(msg)")
            self?.setMain(.failed) { self?.connState = $0 }
            self?.onDisconnected?()
        }
        sk.on("response_mode") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any],
                  let label = obj["label"] as? String else { return }
            self?.setMain(label) { self?.modeLabel = $0 }
        }
        sk.on("current_model") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any],
                  let label = obj["label"] as? String else { return }
            self?.setMain(label) { self?.modelLabel = $0 }
        }
        sk.on("feature_sync") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any],
                  let flags = obj["data"] as? [String: Any] else { return }
            self?.setMain(FeatureFlags.from(flags)) { self?.features = $0 }
        }
        sk.on("ai_thinking") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any] else { return }
            let value = (obj["data"] as? Bool) ?? false
            self?.setMain(value) { self?.thinking = $0 }
            if value {
                // 桌面端开始新回答时已清空缓存，客户端同步清空
                self?.setMain(0) { self?.lastSeq = $0 }
                self?.setMain("") { self?.answerText = $0 }
            }
        }
        sk.on("answer_clear") { [weak self] _, _ in
            self?.setMain(0) { self?.lastSeq = $0 }
            self?.setMain(false) { self?.thinking = $0 }
            self?.setMain("") { self?.answerText = $0 }
        }
        sk.on("answer_stream_chunk") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any],
                  let seq = obj["seq"] as? Int,
                  let content = obj["content"] as? String else { return }
            self?.appendChunk(seq: seq, content: content)
        }
        sk.on("answer_resync") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any] else { return }
            let text = obj["text"] as? String ?? ""
            let nextSeq = obj["nextSeq"] as? Int ?? 1
            let isThinking = obj["thinking"] as? Bool ?? false
            self?.applyResync(text: text, nextSeq: nextSeq, thinking: isThinking)
        }
        // ---- 云端中继专属 ----
        sk.on("host_list") { [weak self] data, _ in
            guard let obj = data.first as? [String: Any],
                  let list = obj["hosts"] as? [[String: Any]] else { return }
            let hosts = list.compactMap { entry -> RelayHost? in
                guard let id = entry["id"] as? String else { return nil }
                let name = entry["name"] as? String ?? "未命名电脑"
                return RelayHost(id: id, name: name)
            }
            PiPDebug.log("云端：收到设备列表，共 \(hosts.count) 台")
            self?.setMain(hosts) { self?.hosts = $0 }
        }
        sk.on("bound") { [weak self] _, _ in
            guard let self = self else { return }
            PiPDebug.log("云端：配对成功，进入会话")
            self.lastSeq = 0
            self.setMain(.connected) { self.connState = $0 }
            sk.emit("answer_resync")
        }
        sk.on("bind_failed") { [weak self] data, _ in
            guard let self = self else { return }
            let obj = data.first as? [String: Any]
            let msg = obj?["message"] as? String ?? "配对失败，请确认 6 位访问码"
            PiPDebug.log("云端：配对失败 - \(msg)")
            self.setMain(msg) { self.bindError = $0 }
        }
        sk.on("host_gone") { [weak self] _, _ in
            guard let self = self else { return }
            self.setMain("所选设备已离线") { self.bindError = $0 }
            self.setMain(.disconnected) { self.connState = $0 }
            self.onDisconnected?()
        }
    }

    private func appendChunk(seq: Int, content: String) {
        guard seq > lastSeq else { return } // 乱序/重复分片直接丢弃
        lastSeq = seq
        setMain(content) { [weak self] piece in
            self?.answerText += piece
        }
    }

    private func applyResync(text: String, nextSeq: Int, thinking: Bool) {
        setMain(text) { self.answerText = $0 }
        setMain(thinking) { self.thinking = $0 }
        setMain(nextSeq - 1) { self.lastSeq = $0 }
    }

    /// Socket 回调来自内部队列，所有状态写入统一切回主线程
    private func setMain<T>(_ value: T, _ apply: @escaping (T) -> Void) {
        DispatchQueue.main.async { apply(value) }
    }
}
