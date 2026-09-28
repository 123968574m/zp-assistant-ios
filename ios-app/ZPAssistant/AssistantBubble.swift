import SwiftUI

/// ZP 助手悬浮球：可拖动的圆形按钮，点开展开半透明面板实时显示提示词。
/// 说明：iOS 不允许第三方应用悬浮在其它应用上方，此悬浮球作用于本 App 内。
struct AssistantBubble: View {
    @EnvironmentObject var store: SessionStore

    @State private var expanded = false
    @State private var anchor: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @AppStorage("bubbleFontSize") private var fontSize: Double = 17

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                if expanded {
                    panel
                        .frame(width: geo.size.width * 0.92, height: geo.size.height * 0.55)
                        .padding(.trailing, geo.size.width * 0.04)
                        .padding(.bottom, 96)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                ball
                    .frame(width: 54, height: 54)
                    .offset(x: anchor.width + dragOffset.width, y: anchor.height + dragOffset.height)
            }
            .padding(.trailing, 14)
            .padding(.bottom, 90)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var ball: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.blue, Color.cyan],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(radius: 4)
            VStack(spacing: 0) {
                Text("ZP").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                if store.thinking {
                    Circle().fill(Color.yellow).frame(width: 7, height: 7)
                }
            }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
        .onTapGesture { withAnimation { expanded.toggle() } }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    anchor = CGSize(width: anchor.width + value.translation.width,
                                    height: anchor.height + value.translation.height)
                    dragOffset = .zero
                }
        )
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("ZP助手 · 提示词")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.white)
                if store.thinking {
                    Text("生成中…").font(.caption2).foregroundColor(.yellow)
                }
                Spacer()
                Button { fontSize = max(12, fontSize - 1) } label: {
                    Image(systemName: "minus.circle").foregroundColor(.white)
                }
                Text("\(Int(fontSize))").font(.caption).foregroundColor(.white.opacity(0.8))
                Button { fontSize = min(30, fontSize + 1) } label: {
                    Image(systemName: "plus.circle").foregroundColor(.white)
                }
                Button {
                    withAnimation { expanded = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().background(Color.white.opacity(0.25))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.system(size: fontSize, weight: .regular))
                        .foregroundColor(.white)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("bubble.answer")
                }
                .onChange(of: store.answerText) { _ in
                    proxy.scrollTo("bubble.answer", anchor: .bottom)
                }
            }
        }
        .background(Color.black.opacity(0.86))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }

    private var displayText: String {
        if store.thinking && store.answerText.isEmpty { return "AI 正在生成…" }
        if store.answerText.isEmpty { return "暂无提示词" }
        return store.answerText
    }
}
