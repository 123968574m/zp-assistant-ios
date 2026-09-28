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
            } else {
                ConnectView()
            }
        }
    }
}
