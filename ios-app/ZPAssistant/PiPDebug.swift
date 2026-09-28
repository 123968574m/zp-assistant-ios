import SwiftUI
import UIKit

/// PiP 调试日志（App 内实时可见，可一键复制）
final class PiPDebug: ObservableObject {
    static let shared = PiPDebug()
    @Published var lines: [String] = []

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ msg: String) {
        DispatchQueue.main.async {
            let line = "[\(df.string(from: Date()))] \(msg)"
            shared.lines.insert(line, at: 0)
            if shared.lines.count > 80 {
                shared.lines.removeLast(shared.lines.count - 80)
            }
        }
    }
}

/// 调试日志查看器
struct PiPDebugSheet: View {
    @ObservedObject private var dbg = PiPDebug.shared

    var body: some View {
        NavigationView {
            ZStack {
                Color.navBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if dbg.lines.isEmpty {
                        Text("暂无日志\n点一次悬浮按钮后再来看")
                            .foregroundColor(.navMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(dbg.lines, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(line.contains("失败") || line.contains("错误") || line.contains("error")
                                                         ? .navRed
                                                         : (line.contains("OK") || line.contains("已启动") ? .navGreen : .navText))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(12)
                        }
                    }
                }
            }
            .navigationTitle("PiP 调试日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = dbg.lines.joined(separator: "\n")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}
