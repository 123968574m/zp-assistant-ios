import SwiftUI

/// 会话主界面：状态栏 + 提示词全文 + 远程控制按钮。
struct SessionView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            answerArea
            Divider()
            controls
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.modeLabel.isEmpty ? "模式未知" : store.modeLabel)
                    .font(.subheadline).fontWeight(.semibold)
                Text(store.modelLabel.isEmpty ? "模型未知" : store.modelLabel)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                store.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var answerArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if store.thinking && store.answerText.isEmpty {
                        Text("AI 正在生成…")
                            .foregroundColor(.secondary)
                    } else if store.answerText.isEmpty {
                        Text("等待桌面端生成提示词…\n在电脑上按截图快捷键后，回答会实时显示在这里和悬浮球里。")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(store.answerText)
                    }
                }
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .id("answer.full")
            }
            .onChange(of: store.answerText) { _ in
                proxy.scrollTo("answer.full", anchor: .bottom)
            }
        }
    }

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ControlButton(title: "截图", icon: "camera.fill",
                          enabled: store.features.screenshot) { store.send(action: "screenshot") }
            ControlButton(title: "切换模式", icon: "arrow.triangle.2.circlepath",
                          enabled: store.features.switchMode) { store.send(action: "switchMode") }
            ControlButton(title: "停止生成", icon: "stop.fill",
                          enabled: store.features.stopGeneration) { store.send(action: "stopGeneration") }
            ControlButton(title: "清空文字", icon: "trash",
                          enabled: store.features.clearText) { store.send(action: "clearText") }
            ControlButton(title: "语音对话", icon: "mic.fill",
                          enabled: store.features.voice) { store.send(action: "voice") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ControlButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
