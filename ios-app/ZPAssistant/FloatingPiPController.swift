import AVKit
import AVFoundation
import SwiftUI
import UIKit

/// 系统级悬浮 —— 视频通话型画中画。
/// 交互模型：悬浮模式开启时，小窗只存在于"应用在后台"期间——
///   点悬浮按钮 → 自动回桌面（小窗出现）→ 回到应用（小窗自动关闭）→ 再去后台（自动再开）。
/// 若小窗被系统折叠成贴边小条，检测到尺寸骤缩后会主动重开。
final class FloatingPiPController: NSObject, ObservableObject {
    static let shared = FloatingPiPController()

    @Published var active = false          // 小窗当前是否显示
    @Published var floatingEnabled = false // 悬浮模式开关（用户意图）

    private var pipController: AVPictureInPictureController?
    private var contentSource: AVPictureInPictureController.ContentSource?
    private var callVC: AVPictureInPictureVideoCallViewController?
    private var sourceView: UIView?
    private var silencePlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var userStopRequested = false
    private var suppressRestart = false
    private var inForeground = true
    private var restartAttempts = 0
    private var restartTimer: Timer?
    private var collapseFixTimer: Timer?
    private var healthPollTimer: Timer?
    private var healthFailCount = 0
    private var healthURL: URL?
    private weak var hostStore: SessionStore?

    /// 悬浮模式开关：开 = 建 PiP + 自动回桌面；关 = 关窗清理
    func toggleFloating(store: SessionStore) {
        if floatingEnabled {
            PiPDebug.log("悬浮模式：关闭")
            floatingEnabled = false
            userStopRequested = true
            pipController?.stopPictureInPicture()
            cleanup()
        } else {
            PiPDebug.log("悬浮模式：开启（0.35s 后自动回桌面）")
            floatingEnabled = true
            hostStore = store
            buildPiP(store: store)
            // 自动回到桌面，小窗随应用进入后台自动呈现
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                UIApplication.shared.perform(Selector(("suspend")))
            }
        }
    }

    private func buildPiP(store: SessionStore) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            PiPDebug.log("错误：设备不支持 PiP")
            return
        }
        restartAttempts = 0
        suppressRestart = false
        applyAudioSession()
        startSilenceLoop()
        startInterruptionGuard()
        startAppStateObservers()
        // 连接断开（手动断开/掉线/对方离线）时主动关闭小窗
        store.onDisconnected = { [weak self] in
            self?.handleConnectionLost()
        }
        // 局域网模式：轮询桌面端 /__health，弥补 socket 超时检测慢的问题
        if store.isLanMode, let url = store.lanHealthURL {
            healthURL = url
            startHealthPoll()
        }

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) else {
            PiPDebug.log("错误：找不到 keyWindow")
            return
        }

        // 悬浮内容：原生 SwiftUI 提示词面板
        let callVC = AVPictureInPictureVideoCallViewController()
        callVC.preferredContentSize = CGSize(width: 720, height: 405)
        let hosting = UIHostingController(rootView: FloatingPanelView().environmentObject(store))
        hosting.view.backgroundColor = .black
        callVC.addChild(hosting)
        hosting.view.frame = callVC.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        callVC.view.addSubview(hosting.view)
        hosting.didMove(toParent: callVC)
        self.callVC = callVC

        // 通话源视图：全屏透明垫底（AVKit 要求源视图在屏）
        let sourceView = UIView(frame: window.bounds)
        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(sourceView, at: 0)
        self.sourceView = sourceView

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: callVC)
        contentSource = source
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
        PiPDebug.log("PiP 构建完成，等应用进入后台自动呈现")
    }

    func stop() {
        floatingEnabled = false
        userStopRequested = true
        pipController?.stopPictureInPicture()
        cleanup()
    }

    private func cleanup() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
            backgroundObserver = nil
        }
        restartTimer?.invalidate()
        restartTimer = nil
        collapseFixTimer?.invalidate()
        collapseFixTimer = nil
        healthPollTimer?.invalidate()
        healthPollTimer = nil
        healthFailCount = 0
        healthURL = nil
        userStopRequested = false
        suppressRestart = false
        inForeground = true
        restartAttempts = 0
        silencePlayer?.stop()
        silencePlayer = nil
        callVC?.view.removeFromSuperview()
        callVC = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        contentSource = nil
        pipController = nil
        DispatchQueue.main.async { self.active = false }
    }
}

// MARK: - 前后台联动

extension FloatingPiPController {

    fileprivate func startAppStateObservers() {
        // 回到应用：主动关闭小窗（bug1）。前后台切换过程中 stop 可能被系统忽略，
        // 因此立即关一次 + 0.4s 后补关一次。
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.floatingEnabled else { return }
            PiPDebug.log("回应用：关闭小窗")
            self.inForeground = true
            self.closeWindowForForeground()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, self.inForeground, self.floatingEnabled else { return }
                PiPDebug.log("回应用：0.4s 补关")
                self.pipController?.stopPictureInPicture()
            }
        }
        // 去后台：主动拉起小窗
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.floatingEnabled,
                  let pip = self.pipController else { return }
            PiPDebug.log("去后台：拉起小窗")
            self.inForeground = false
            self.suppressRestart = false
            self.reassertSession()
            pip.startPictureInPicture()
        }
    }

    private func closeWindowForForeground() {
        suppressRestart = true
        pipController?.stopPictureInPicture()
    }
}

// MARK: - 音频会话（保活 + 混音）

extension FloatingPiPController {

    private func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers])
            try session.setActive(true)
            PiPDebug.log("音频会话 OK：playAndRecord/videoChat/mix")
        } catch {
            PiPDebug.log("playAndRecord 失败：\(error.localizedDescription)，退回 playback")
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }

    fileprivate func startInterruptionGuard() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let kind = raw == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended"
            PiPDebug.log("音频打断：\(kind)")
            self.reassertSession()
        }
    }

    /// 局域网健康轮询：连续 2 次失败即判定桌面端断开
    fileprivate func startHealthPoll() {
        healthPollTimer?.invalidate()
        healthFailCount = 0
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.floatingEnabled, let url = self.healthURL else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 2.5
            URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
                let ok = (error == nil) && ((response as? HTTPURLResponse)?.statusCode == 200)
                DispatchQueue.main.async {
                    guard let self = self, self.floatingEnabled else { return }
                    if ok {
                        self.healthFailCount = 0
                    } else {
                        self.healthFailCount += 1
                        PiPDebug.log("局域网健康检查失败 x\(self.healthFailCount)")
                        if self.healthFailCount >= 2 {
                            self.handleConnectionLost()
                        }
                    }
                }
            }.resume()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthPollTimer = timer
    }

    /// 连接断开：关小窗 + 退出悬浮模式
    fileprivate func handleConnectionLost() {
        guard floatingEnabled else { return }
        PiPDebug.log("连接已断开：关闭小窗并退出悬浮模式")
        floatingEnabled = false
        userStopRequested = true
        pipController?.stopPictureInPicture()
        // 关窗是异步的：0.6s 后补关一次并清理（didStop 也会触发 cleanup，二者幂等）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if self.pipController != nil {
                PiPDebug.log("断开关窗：0.6s 补关")
                self.pipController?.stopPictureInPicture()
            }
            self.cleanup()
        }
    }

    fileprivate func reassertSession() {
        applyAudioSession()
        silencePlayer?.play()
    }

    fileprivate func startSilenceLoop() {
        let sampleRate = 8000
        let dataSize = sampleRate * 2 * 2 // 2 秒 16bit 单声道
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataSize))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1); le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        wav.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataSize))
        wav.append(Data(count: dataSize))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        try? wav.write(to: url)
        silencePlayer = try? AVAudioPlayer(contentsOf: url)
        silencePlayer?.numberOfLoops = -1
        silencePlayer?.volume = 0.01
        let ok = silencePlayer?.play() ?? false
        PiPDebug.log("静音保活：\(ok ? "OK" : "失败")")
    }
}

// MARK: - 悬浮面板（原生 SwiftUI；全文一页，字号自适应缩放）

struct FloatingPanelView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("领航者")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.navAccent)
                if store.thinking {
                    Text("生成中…")
                        .font(.system(size: 12))
                        .foregroundColor(.yellow)
                }
                Spacer()
                Text(store.modeLabel.isEmpty ? " " : store.modeLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.navMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(navHex: 0x123C6E))
            Divider().overlay(Color.navBorder)

            // 所有的字呈现在同一页：字号按内容量自动缩小直到整篇放下
            Text(displayText)
                .font(.system(size: 15))
                .foregroundColor(.navText)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .minimumScaleFactor(0.12)
        }
        .background(Color.navBg)
    }

    private var displayText: String {
        if store.thinking && store.answerText.isEmpty { return "AI 正在生成…" }
        if store.answerText.isEmpty { return "等待桌面端生成提示词…" }
        return store.answerText
    }
}

// MARK: - PiP 委托（折叠检测 + 自动重拉）

extension FloatingPiPController: AVPictureInPictureControllerDelegate {

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // 小窗被折叠成贴边小条时，系统请求的渲染尺寸会骤缩——主动重开
        PiPDebug.log("渲染尺寸：\(newRenderSize.width)x\(newRenderSize.height)")
        if newRenderSize.width < 120 && floatingEnabled && !suppressRestart && !inForeground && active {
            // 保持小窗始终展开：检测到折叠立即重启小窗
            PiPDebug.log("检测到折叠，0.25s 后重启小窗")
            collapseFixTimer?.invalidate()
            collapseFixTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let self = self, self.floatingEnabled, let pip = self.pipController else { return }
                self.suppressRestart = true
                pip.stopPictureInPicture()
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    guard let self = self, self.floatingEnabled, let pip = self.pipController else { return }
                    self.suppressRestart = false
                    self.reassertSession()
                    pip.startPictureInPicture()
                }
            }
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.active = true
            self.restartAttempts = 0
            PiPDebug.log("小窗已显示")
            if self.inForeground && self.floatingEnabled {
                // 前台期间系统自动弹出的：立即关闭
                PiPDebug.log("前台出现小窗，立即关闭")
                self.suppressRestart = true
                pictureInPictureController.stopPictureInPicture()
            }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        PiPDebug.log("错误：启动失败 \(error.localizedDescription)")
        DispatchQueue.main.async {
            if !self.userStopRequested && !self.suppressRestart { self.scheduleRestart() }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            if self.userStopRequested {
                PiPDebug.log("小窗关闭（用户关闭）")
                self.cleanup()
                return
            }
            if self.suppressRestart {
                self.active = false
                PiPDebug.log("小窗关闭（回到前台）")
                return
            }
            PiPDebug.log("小窗意外终止，自动重拉")
            self.active = false
            self.scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        guard restartAttempts < 8 else {
            PiPDebug.log("重试次数用尽，停止重拉")
            cleanup()
            return
        }
        restartAttempts += 1
        restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self, self.floatingEnabled, !self.inForeground,
                  let pip = self.pipController else { return }
            self.reassertSession()
            pip.startPictureInPicture()
        }
    }
}
