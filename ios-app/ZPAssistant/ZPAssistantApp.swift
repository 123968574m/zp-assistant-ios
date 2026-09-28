import SwiftUI

@main
struct ZPAssistantApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: SessionStore
    @State private var showDebug = false

    var body: some View {
        ZStack {
            Color.navBg.ignoresSafeArea()
            if store.connState == .connected {
                SessionView()
                // ZP 助手悬浮球：已连接时常驻，点开展开提示词面板
                AssistantBubble()
            } else {
                ConnectView()
            }
            VStack {
                Spacer()
                HStack {
                    Button {
                        showDebug = true
                    } label: {
                        Image(systemName: "ladybug")
                            .font(.system(size: 13))
                            .foregroundColor(.navMuted)
                            .frame(width: 30, height: 30)
                            .background(Color.navSurface.opacity(0.9))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.navBorder, lineWidth: 1))
                    }
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showDebug) { PiPDebugSheet() }
    }
}
