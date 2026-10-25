import SwiftUI

/// 会话主界面：品牌状态栏 + 提示词卡片 + 远程控制，暗色视觉。
struct SessionView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject private var pip = FloatingPiPController.shared
    @AppStorage("autoSearchEnabled") private var autoSearchEnabled = false
    @AppStorage("autoSearchInterval") private var autoSearchInterval = "45"
    @State private var autoSearchTimer: Timer?

    var body: some View {
        ZStack {
            Color.navBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.navBorder)
                answerArea
                Divider().overlay(Color.navBorder)
                autoSearchRow
                controls
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Timer 在后台被系统暂停：回前台时若开关仍开则继续
            if autoSearchEnabled && autoSearchTimer == nil && store.isConnected {
                store.sendScreenshotThrottled()
                startAutoSearchTimer()
            }
        }
        .onDisappear {
            autoSearchTimer?.invalidate()
            autoSearchTimer = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.navAccent, Color(navHex: 0x123C6E)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("领航者").font(.subheadline).fontWeight(.bold).foregroundColor(.navText)
                HStack(spacing: 6) {
                    Circle().fill(store.connState == .connected ? Color.navGreen : Color.navRed)
                        .frame(width: 6, height: 6)
                    Text(store.modeLabel.isEmpty ? "未同步模式" : store.modeLabel)
                        .font(.caption).foregroundColor(.navMuted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(store.modelLabel.isEmpty ? "模型未知" : store.modelLabel)
                    .font(.caption).foregroundColor(.navMuted)
            }
            Button {
                pip.toggleFloating(store: store)
            } label: {
                Image(systemName: pip.floatingEnabled ? "pip.exit" : "pip.enter")
                    .font(.title3)
                    .foregroundColor(pip.floatingEnabled ? .navAccent : .navMuted)
                    .frame(width: 38, height: 38)
                    .background(Color.navSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.navBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                store.disconnect()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.navMuted)
                    .frame(width: 38, height: 38)
                    .background(Color.navSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.navBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var answerArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if store.thinking && store.answerText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().tint(.navAccent)
                            Text("AI 正在生成…").foregroundColor(.navMuted)
                        }
                    } else if store.answerText.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.largeTitle)
                                .foregroundColor(.navBorder)
                            Text("等待桌面端生成提示词")
                                .foregroundColor(.navMuted)
                            Text("在电脑上按截图快捷键后，回答会实时显示在这里和悬浮窗里。")
                                .font(.footnote)
                                .foregroundColor(.navMuted.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        Text(store.answerText)
                            .foregroundColor(.navText)
                    }
                }
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: store.answerText.isEmpty ? .center : .leading)
                .padding(16)
                .id("answer.full")
            }
            .onChange(of: store.answerText) { _ in
                proxy.scrollTo("answer.full", anchor: .bottom)
            }
        }
    }

    // 自动搜题：开启即发第一次截图（计时起点），之后每 n 秒一次
    private var autoSearchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.navAccent)
                .frame(width: 30)
            Text("自动搜题")
                .font(.subheadline)
                .foregroundColor(.navText)
            Spacer()
            TextField("秒", text: $autoSearchInterval)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 52, height: 30)
                .background(Color.navSurface)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.navBorder, lineWidth: 1))
            Text("秒/次")
                .font(.caption2)
                .foregroundColor(.navMuted)
            Toggle("", isOn: Binding(
                get: { autoSearchEnabled },
                set: { on in
                    autoSearchEnabled = on
                    if on {
                        store.sendScreenshotThrottled()
                        startAutoSearchTimer()
                    } else {
                        autoSearchTimer?.invalidate()
                        autoSearchTimer = nil
                    }
                }
            ))
            .labelsHidden()
            .tint(.navAccent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.navSurface)
    }

    private func startAutoSearchTimer() {
        autoSearchTimer?.invalidate()
        let n = Double(autoSearchInterval) ?? 45
        guard n >= 5 else { return }
        autoSearchTimer = Timer.scheduledTimer(withTimeInterval: n, repeats: true) { _ in
            store.sendScreenshotThrottled()
        }
    }

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ControlButton(title: "截图", icon: "camera.fill", tint: .navAccent,
                          enabled: store.features.screenshot) { store.sendScreenshotThrottled() }
            ControlButton(title: "切换模式", icon: "arrow.triangle.2.circlepath", tint: .navAccent,
                          enabled: store.features.switchMode) { store.send(action: "switchMode") }
            ControlButton(title: "停止生成", icon: "stop.fill", tint: .navRed,
                          enabled: store.features.stopGeneration) { store.send(action: "stopGeneration") }
            ControlButton(title: "清空文字", icon: "trash", tint: .navMuted,
                          enabled: store.features.clearText) { store.send(action: "clearText") }
            ControlButton(title: "语音对话", icon: "mic.fill", tint: .navGreen,
                          enabled: store.features.voice) { store.send(action: "voice") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ControlButton: View {
    let title: String
    let icon: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(enabled ? tint : .navMuted.opacity(0.5))
                Text(title)
                    .font(.caption)
                    .foregroundColor(enabled ? .navText : .navMuted.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.navSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.navBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
