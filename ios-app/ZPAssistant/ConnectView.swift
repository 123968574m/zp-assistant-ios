import SwiftUI

/// 连接页：扫码或手动输入桌面端地址；连接参数自动记忆。
struct ConnectView: View {
    @EnvironmentObject var store: SessionStore

    @AppStorage("lastHost") private var host = ""
    @AppStorage("lastPort") private var port = "9696"
    @AppStorage("lastRoom") private var room = ""
    @AppStorage("lastPassword") private var password = ""

    @State private var showScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("桌面端连接")) {
                    HStack {
                        TextField("电脑 IP，如 192.168.1.5", text: $host)
                            .keyboardType(.decimalPad)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                    TextField("端口（默认 9696）", text: $port)
                        .keyboardType(.numberPad)
                    TextField("房间号 room（扫码自动带出）", text: $room)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("密码（桌面端未设置则留空）", text: $password)
                }

                Section {
                    Button {
                        errorMessage = nil
                        store.connect(host: host, port: port, room: room, password: password)
                    } label: {
                        HStack {
                            Spacer()
                            Text(store.connState == .connecting ? "连接中…" : "连接桌面端")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(store.connState == .connecting || host.isEmpty || room.isEmpty)
                }

                if let msg = errorMessage {
                    Section {
                        Text(msg).font(.footnote).foregroundColor(.red)
                    }
                }
                if store.connState == .failed {
                    Section {
                        Text("连接失败：请确认手机与电脑在同一 Wi-Fi、桌面端已开启手机互联、IP/端口/房间号正确。")
                            .font(.footnote).foregroundColor(.red)
                    }
                }

                Section(header: Text("使用说明"), footer: Text("桌面端「手机互联」开启后会在窗口显示二维码，点右上角扫码即可自动填入 IP/端口/房间号。")) {
                    Text("1. 桌面端开启手机互联\n2. 点右上角扫码，或手动填写\n3. 连接成功后进入会话页，悬浮球实时显示提示词")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("ZP助手")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showScanner) {
            QRScannerView { text in
                showScanner = false
                parseScanned(text)
            }
            .ignoresSafeArea()
        }
    }

    /// 桌面端二维码内容: http://<ip>:<port>/?room=<roomId>
    private func parseScanned(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https",
              let h = url.host else {
            errorMessage = "二维码内容无法识别：\(text)"
            return
        }
        host = h
        port = url.port.map(String.init) ?? "9696"
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let r = comps.queryItems?.first(where: { $0.name == "room" })?.value, !r.isEmpty {
            room = r
        }
    }
}
