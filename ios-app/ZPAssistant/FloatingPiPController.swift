import AVKit
import AVFoundation
import WebKit
import UIKit

/// 系统级悬浮（画中画）：提示词面板由离屏 WKWebView 渲染 HTML（含实时时钟），
/// 定时截图推进 AVSampleBuffer 视频流，PiP 窗口悬浮在系统和任何应用上方。
/// 后台持续渲染依赖：UIBackgroundModes=audio + 静音循环保活。
final class FloatingPiPController: NSObject, ObservableObject {
    static let shared = FloatingPiPController()

    @Published var active = false

    private var sampleLayer: AVSampleBufferDisplayLayer?
    private var contentSource: AVPictureInPictureController.ContentSource?
    private var pipController: AVPictureInPictureController?
    private var renderTimer: Timer?
    private var pool: CVPixelBufferPool?
    private var frameCount: Int64 = 0
    private var silencePlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var webView: WKWebView?
    private var snapshotInFlight = false
    private var lastSentStatus = "\u{0}"
    private var lastSentText = "\u{0}"
    private var textProvider: (() -> String)?
    private var statusProvider: (() -> String)?

    private let renderWidth = 720
    private let renderHeight = 405

    func start(text: @escaping () -> String, status: @escaping () -> String) {
        guard !active else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        textProvider = text
        statusProvider = status

        // 后台保活：playback 会话 + 静音循环
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：声明可混音，其它 App（视频会议/相机）激活语音会话时
        // 不会打断我们，PiP 窗口因此不会被系统挂起成禁用状态
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        startSilenceLoop()
        startInterruptionGuard()

        // 1) 离屏 WebView：渲染提示词面板（时钟/状态/正文）
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) {
            let holder = UIView(frame: CGRect(x: -renderWidth - 4, y: 0,
                                              width: renderWidth, height: renderHeight))
            holder.addSubview(webView)
            window.addSubview(holder)
        }
        webView.loadHTMLString(Self.panelHTML(), baseURL: nil)
        self.webView = webView
        lastSentStatus = "\u{0}"
        lastSentText = "\u{0}"

        // 2) PiP 视频源
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        sampleLayer = layer
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self)
        contentSource = source

        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip

        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) {
            let holder = UIView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
            holder.layer.addSublayer(layer)
            window.addSubview(holder)
        }

        // 3) 像素缓冲池
        var attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: renderWidth,
            kCVPixelBufferHeightKey: renderHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        pool = newPool

        frameCount = 0
        pip.startPictureInPicture()

        // 4) 10fps：同步内容 → 截图 → 推帧
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncContent()
            self?.captureFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
        DispatchQueue.main.async { self.active = true }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        cleanup()
    }

    private func cleanup() {
        renderTimer?.invalidate()
        renderTimer = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        silencePlayer?.stop()
        silencePlayer = nil
        sampleLayer?.flush()
        sampleLayer?.removeFromSuperlayer()
        sampleLayer = nil
        contentSource = nil
        pipController = nil
        webView?.removeFromSuperview()
        webView = nil
        pool = nil
        DispatchQueue.main.async { self.active = false }
    }

    // MARK: - 内容同步与截图

    private func syncContent() {
        guard let webView = webView else { return }
        let status = statusProvider?() ?? ""
        let text = textProvider?() ?? ""
        if status != lastSentStatus || text != lastSentText {
            lastSentStatus = status
            lastSentText = text
            if let data = try? JSONSerialization.data(withJSONObject: [status, text]),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("update.apply(null, \(json))", completionHandler: nil)
            }
        }
    }

    private func captureFrame() {
        guard !snapshotInFlight, let webView = webView else { return }
        snapshotInFlight = true
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            self?.snapshotInFlight = false
            if let image = image { self?.enqueue(image) }
        }
    }

    private func enqueue(_ image: UIImage) {
        guard let pool = pool, let layer = sampleLayer else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let buffer = pb else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: renderWidth, height: renderHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        pushFrame(buffer, to: layer)
    }
}

// MARK: - 推帧

extension FloatingPiPController {

    fileprivate func pushFrame(_ buffer: CVPixelBuffer, to layer: AVSampleBufferDisplayLayer) {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(value: frameCount, timescale: 10),
            decodeTimeStamp: CMTime.invalid
        )
        frameCount += 1
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDesc)
        guard let format = formatDesc else { return }
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard createStatus == noErr, let sb = sampleBuffer else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            (arr as NSArray).forEach { entry in
                (entry as? NSMutableDictionary)?[kCMSampleAttachmentKey_DisplayImmediately as String] = NSNumber(value: true)
            }
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }
}

// MARK: - 悬浮面板 HTML（实时时钟 + 提示词）

extension FloatingPiPController {

    static func panelHTML() -> String {
        return """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=720">
<style>
body{margin:0;width:720px;height:405px;background:#0c0e12;color:#e8e8ec;font-family:-apple-system,'PingFang SC',sans-serif;overflow:hidden}
.bar{display:flex;justify-content:space-between;align-items:center;padding:8px 20px;background:linear-gradient(90deg,#123c6e,#0c0e12);border-bottom:1px solid #2a2f3a}
.brand{color:#4dabf7;font-weight:700;font-size:19px;letter-spacing:1px}
#st{color:#ffb340;font-size:15px;margin-left:auto;margin-right:18px}

#text{padding:14px 22px;font-size:29px;line-height:1.5;white-space:pre-wrap;word-break:break-all;height:316px;overflow:hidden}
</style></head><body>
<div class="bar"><span class="brand">领航者</span><span id="st"></span></div>
<div id="text">等待桌面端生成提示词…</div>
<script>
var EMPTY='等待桌面端生成提示词…';
function update(st,text){document.getElementById('st').textContent=st;var el=document.getElementById('text');el.textContent=text||EMPTY;el.scrollTop=el.scrollHeight}
</script></body></html>
"""
    }
}

// MARK: - 音频会话守卫

extension FloatingPiPController {

    fileprivate func startInterruptionGuard() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            if raw == AVAudioSession.InterruptionType.began.rawValue {
                // 立即重新激活会话并恢复静音播放，把 PiP 从挂起边缘拉回来
                try? AVAudioSession.sharedInstance().setActive(true)
                self.silencePlayer?.play()
            } else {
                let option = (note.userInfo?[AVAudioSessionInterruptionOptionsKey] as? NSNumber)?.uintValue
                if option == AVAudioSession.InterruptionOptions.shouldResume.rawValue {
                    self.silencePlayer?.play()
                }
            }
        }
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

// MARK: - PiP 委托

extension FloatingPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) { /* 静态流，无需播放控制 */ }

    func pictureInPictureControllerTimeRange(_ pictureInPictureController: AVPictureInPictureController,
                                             didChange timeRange: CMTimeRange) { }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(value: CMTimeValue(max(0, frameCount - 1)), timescale: 10),
            duration: CMTime(value: 1, timescale: 10)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) { }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

extension FloatingPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        cleanup()
    }
}
