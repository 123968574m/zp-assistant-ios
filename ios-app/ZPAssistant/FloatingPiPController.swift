import AVKit
import AVFoundation
import SwiftUI
import UIKit

/// 系统级悬浮 —— 视频通话型画中画（FaceTime 同款通道）。
/// 关键差异：媒体播放型 PiP 会被其它 App 的视频/摄像头踢掉（显示禁止按钮），
/// 而视频通话型 PiP 属于"通话"槽位，可与腾讯视频、相机等共存，且无播放/暂停控件。
/// 悬浮内容 = 原生 SwiftUI 面板（随提示词实时刷新），无需截图推流。
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

    func start(store: SessionStore) {
        guard !active else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        userStopRequested = false
        restartAttempts = 0

        applyAudioSession()
        startSilenceLoop()
        startInterruptionGuard()

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) else { return }

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

        // 2) 通话源视图（挂到窗口外，仅作注册用）
        let sourceView = UIView(frame: CGRect(x: -4, y: -4, width: 2, height: 2))
        window.addSubview(sourceView)
        self.sourceView = sourceView

        // 3) 视频通话型 PiP
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: callVC)
        contentSource = source
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
        pip.startPictureInPicture()
    }

    func stop() {
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
    }
}

// MARK: - 音频会话（保活 + 混音）

extension FloatingPiPController {

    private func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // 视频通话语义 + 可混音：不被其它 App 的媒体播放/语音会话打断
        try? session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers])
        try? session.setActive(true)
        if session.category != .playAndRecord {
            // 个别设备激活失败时退回普通播放档
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
            if raw == AVAudioSession.InterruptionType.began.rawValue ||
               raw == AVAudioSession.InterruptionType.ended.rawValue {
                self.reassertSession()
            }
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
        silencePlayer?.play()
    }
}

// MARK: - 悬浮面板（原生 SwiftUI，实时刷新）

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
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.system(size: 14))
                        .foregroundColor(.navText)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("pip.text")
                }
                .onChange(of: store.answerText) { _ in
                    proxy.scrollTo("pip.text", anchor: .bottom)
                }
            }
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
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            if self.userStopRequested {
                self.cleanup()
                return
            }
            // 非用户关闭（被系统/其它场景终止）：自动重拉
            self.active = false
            self.scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        guard restartAttempts < 8 else {
            cleanup()
            return
        }
        restartAttempts += 1
        restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self, let pip = self.pipController else { return }
            self.reassertSession()
            pip.startPictureInPicture()
        }
    }
}
