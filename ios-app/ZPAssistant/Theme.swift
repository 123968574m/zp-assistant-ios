import SwiftUI

/// 统一暗色视觉（对齐中继网页端配色）
extension Color {
    init(navHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((navHex >> 16) & 0xFF) / 255,
            green: Double((navHex >> 8) & 0xFF) / 255,
            blue: Double(navHex & 0xFF) / 255,
            opacity: 1
        )
    }

    static let navBg = Color(navHex: 0x0C0E12)
    static let navSurface = Color(navHex: 0x15181D)
    static let navSurface2 = Color(navHex: 0x1D2128)
    static let navBorder = Color(navHex: 0x2A2F3A)
    static let navAccent = Color(navHex: 0x4DABF7)
    static let navText = Color(navHex: 0xE8E8EC)
    static let navMuted = Color(navHex: 0x8B8D94)
    static let navGreen = Color(navHex: 0x30D158)
    static let navRed = Color(navHex: 0xFF5C5C)
}

/// 品牌标题行：罗盘标 + 应用名
struct BrandHeader: View {
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.navAccent, Color(navHex: 0x123C6E)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("领航者").font(.title3).fontWeight(.bold).foregroundColor(.navText)
                Text(subtitle).font(.caption).foregroundColor(.navMuted)
            }
        }
    }
}

/// 主操作按钮（品牌渐变）
struct NavPrimaryButton: View {
    var title: String
    var loading = false
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if loading { ProgressView().tint(.white) } else {
                    Text(title).font(.headline).foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: [Color(navHex: 0x2B7BD4), Color(navHex: 0x4DABF7)],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(disabled ? 0.4 : 1)
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
    }
}

/// 圆角深色输入框样式
struct NavFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.navSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.navBorder, lineWidth: 1))
    }
}

extension View {
    func navField() -> some View { modifier(NavFieldStyle()) }
}
