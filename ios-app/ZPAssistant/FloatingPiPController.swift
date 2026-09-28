import AVKit
import AVFoundation
import UIKit

/// 系统级悬浮：把提示词实时渲染成视频帧，用画中画（PiP）窗口播放。
/// PiP 窗口可拖动/缩放，悬浮在桌面和任何其它应用之上。
/// 后台持续渲染依赖： UIBackgroundModes=audio + 静音循环保活。
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
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        startSilenceLoop()

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        sampleLayer = layer

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self)
        contentSource = source

        // 挂到窗口外的 1x1 隐藏视图上（PiP 独立渲染窗口内容）
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: { $0.isKeyWindow }) {
            let holder = UIView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
            holder.layer.addSublayer(layer)
            window.addSubview(holder)
        }

        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip

        // 像素缓冲池
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
        renderFrame()
        pip.startPictureInPicture()

        // 10fps 定时重绘（后台靠静音保活持续触发）
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.renderFrame()
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
        silencePlayer?.stop()
        silencePlayer = nil
        sampleLayer?.flush()
        sampleLayer?.removeFromSuperlayer()
        sampleLayer = nil
        contentSource = nil
        pipController = nil
        pool = nil
        DispatchQueue.main.async { self.active = false }
    }

    private func startSilenceLoop() {
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

// MARK: - 帧渲染

extension FloatingPiPController {

    fileprivate func renderFrame() {
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
            drawContent(size: CGSize(width: renderWidth, height: renderHeight))
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

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

    private func drawContent(size: CGSize) {
        let text = textProvider?() ?? ""
        let status = statusProvider?() ?? ""

        // 顶栏：ZP助手 + 状态
        let header = NSMutableAttributedString(
            string: "ZP助手",
            attributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold),
                         .foregroundColor: UIColor.cyan])
        if !status.isEmpty {
            header.append(NSAttributedString(
                string: "   " + status,
                attributes: [.font: UIFont.systemFont(ofSize: 18),
                             .foregroundColor: UIColor.yellow]))
        }
        header.draw(in: CGRect(x: 24, y: 14, width: size.width - 48, height: 30))

        // 正文：按长度自适应字号，超出画布时保留末尾（最新内容）
        let inset: CGFloat = 24
        let avail = CGSize(width: size.width - inset * 2, height: size.height - 66)
        guard !text.isEmpty else {
            NSAttributedString(string: "等待桌面端生成提示词…",
                               attributes: [.font: UIFont.systemFont(ofSize: 30),
                                            .foregroundColor: UIColor.gray])
                .draw(in: CGRect(x: inset, y: 56, width: avail.width, height: avail.height))
            return
        }
        let fontSize: CGFloat = text.count > 600 ? 26 : (text.count > 250 ? 30 : 34)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]

        func textHeight(_ s: String) -> CGFloat {
            NSAttributedString(string: s, attributes: attrs).boundingRect(
                with: CGSize(width: avail.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        }

        var fitted = text
        var h = textHeight(fitted)
        if h > avail.height {
            let drop = Int(CGFloat(fitted.count) * (1 - avail.height / h)) + 1
            fitted = String(fitted.suffix(max(0, fitted.count - drop)))
            if !fitted.hasPrefix("…") { fitted = "…" + fitted }
            h = textHeight(fitted)
            while h > avail.height && fitted.count > 8 {
                fitted = String(fitted.dropFirst(max(8, fitted.count / 10)))
                if !fitted.hasPrefix("…") { fitted = "…" + fitted }
                h = textHeight(fitted)
            }
        }
        NSAttributedString(string: fitted, attributes: attrs)
            .draw(in: CGRect(x: inset, y: 56, width: avail.width, height: avail.height))
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
