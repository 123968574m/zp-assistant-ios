import Foundation
import SocketIO

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
        DispatchQueue.main.async {
            self.connState = .disconnected
            self.answerText = ""
            self.thinking = false
        }
    }

    func send(action: String) {
        socket?.emit("remote_action", ["action": action])
    }

    private func bind(_ sk: SocketIOClient) {
        sk.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            self.lastSeq = 0
            self.setMain(.connected) { self.connState = $0 }
            // 连上后向桌面端要一次当前回答全文，补齐掉线窗口内丢失的分片
            sk.emit("answer_resync")
        }
        sk.on(clientEvent: .disconnect) { [weak self] data, _ in
            // 主动断开(reason=manual)不再重连；其余交给 .reconnects(true)
            let reason = data.first as? String ?? ""
            self?.setMain(reason == "manual" ? .disconnected : .connecting) { self?.connState = $0 }
        }
        sk.on(clientEvent: .error) { [weak self] _, _ in
            self?.setMain(.failed) { self?.connState = $0 }
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
