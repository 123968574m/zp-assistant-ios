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
        }
    }
}
