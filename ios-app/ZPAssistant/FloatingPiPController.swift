import AVKit
import AVFoundation
import SwiftUI
import UIKit

/// 系统级悬浮 —— 视频通话型画中画，全流程埋调试日志（🐞 查看）。
final class FloatingPiPController: NSObject, ObservableObject {
    static let shared = FloatingPiPController()

    @Published var active = false

    private var pipController: AVPictureInPictureController?
    private var contentSource: AVPictureInPictureController.ContentSource?
    private var callVC: AVPictureInPictureVideoCallViewController?
    private var sourceView: UIView?
    private var silencePlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var userStopRequested = false
    private var restartAttempts = 0
    private var restartTimer: Timer?
    private var pipPossibleObservation: NSKeyValueObservation?

    func start(store: SessionStore) {
        guard !active else { PiPDebug.log("已在悬浮中，忽略重复启动"); return }
        userStopRequested = false
        restartAttempts = 0

        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        PiPDebug.log("启动 PiP：iOS \(UIDevice.current.systemVersion)，supported=\(supported)")
        guard supported else { PiPDebug.log("错误：此设备不支持 PiP"); return }

        applyAudioSession()
        startSilenceLoop()
        startInterruptionGuard()

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) else {
            PiPDebug.log("错误：找不到 keyWindow")
            return
        }
        PiPDebug.log("keyWindow OK：\(Int(window.bounds.width))x\(Int(window.bounds.height))")

        // 1) 悬浮内容：原生 SwiftUI 提示词面板
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
        PiPDebug.log("内容面板 OK（SwiftUI 720x405）")

        // 2) 通话源视图：AVKit 要求源视图必须在屏幕上，用全屏透明视图垫底
        let sourceView = UIView(frame: window.bounds)
        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(sourceView, at: 0)
        self.sourceView = sourceView
        PiPDebug.log("源视图 OK（全屏透明垫底，insertSubview at 0）")

        // 3) 视频通话型 PiP
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: callVC)
        contentSource = source
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
        PiPDebug.log("PiP 控制器 OK，isPictureInPicturePossible=\(pip.isPictureInPicturePossible)")

        // isPictureInPicturePossible 变为 true 后再启动
        pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { pip, change in
            if change.newValue == true {
                DispatchQueue.main.async {
                    PiPDebug.log("possible=true，调用 startPictureInPicture")
                    pip.startPictureInPicture()
                }
            }
        }
        if pip.isPictureInPicturePossible {
            PiPDebug.log("初始即 possible=true，调用 startPictureInPicture")
            pip.startPictureInPicture()
        } else {
            PiPDebug.log("等待 possible 变为 true…（10s 未变则重试）")
            restartTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                guard let self = self, !self.active else { return }
                PiPDebug.log("10s 超时仍未 possible，重试一轮")
                self.scheduleRestart()
            }
        }
    }

    func stop() {
        PiPDebug.log("用户主动关闭悬浮")
        userStopRequested = true
        pipController?.stopPictureInPicture()
        cleanup()
    }

    private func cleanup() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        restartTimer?.invalidate()
        restartTimer = nil
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        userStopRequested = false
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
        PiPDebug.log("资源已清理")
    }
}

// MARK: - 音频会话（保活 + 混音）

extension FloatingPiPController {

    fileprivate func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // 视频通话语义 + 可混音：不被其它 App 的媒体播放/语音会话打断
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers])
            try session.setActive(true)
            PiPDebug.log("音频会话 OK：playAndRecord/videoChat/mix")
        } catch {
            PiPDebug.log("playAndRecord 激活失败：\(error.localizedDescription)，退回 playback")
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                PiPDebug.log("音频会话 OK：playback/mix")
            } catch {
                PiPDebug.log("错误：playback 也失败 \(error.localizedDescription)")
            }
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
            PiPDebug.log("音频打断：\(kind)，重新声明会话")
            self.reassertSession()
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
        PiPDebug.log("静音保活播放：\(ok ? "OK" : "失败")")
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

// MARK: - PiP 委托（自动重拉）

extension FloatingPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.active = true
            self.restartAttempts = 0
            PiPDebug.log("PiP 已启动 ✓")
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        PiPDebug.log("错误：启动失败 \(error.localizedDescription)")
        DispatchQueue.main.async {
            if !self.userStopRequested { self.scheduleRestart() }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            PiPDebug.log("PiP 停止（用户关闭=\(self.userStopRequested)）")
            if self.userStopRequested {
                self.cleanup()
                return
            }
            self.active = false
            self.scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        guard restartAttempts < 8 else {
            PiPDebug.log("重试次数用尽，停止自动重拉")
            cleanup()
            return
        }
        restartAttempts += 1
        PiPDebug.log("1s 后自动重拉（第 \(restartAttempts) 次）")
        restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self, let pip = self.pipController else { return }
            self.reassertSession()
            pip.startPictureInPicture()
        }
    }
}
