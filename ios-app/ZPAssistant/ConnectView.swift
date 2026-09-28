import SwiftUI

/// 连接页：局域网扫码 / 云端中继（非局域网）两种模式，暗色品牌视觉。
struct ConnectView: View {
    enum Tab: String, CaseIterable {
        case lan = "局域网 · 扫码"
        case cloud = "云端 · 非局域网"
    }

    @EnvironmentObject var store: SessionStore
    @State private var tab: Tab = .lan

    // 局域网
    @AppStorage("lastHost") private var host = ""
    @AppStorage("lastPort") private var port = "9696"
    @AppStorage("lastRoom") private var room = ""
    @AppStorage("lastPassword") private var password = ""
    @State private var showScanner = false

    // 云端
    @State private var selectedHost: RelayHost?
    @State private var code = ""

    var body: some View {
        ZStack {
            Color.navBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    BrandHeader(subtitle: "面试提示词实时同步")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .colorMultiply(.navAccent)

                    switch tab {
                    case .lan: lanForm
                    case .cloud: cloudForm
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) {
            QRScannerView { text in
                showScanner = false
                parseScanned(text)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - 局域网

    private var lanForm: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TextField("电脑 IP，如 192.168.1.5", text: $host)
                    .keyboardType(.decimalPad)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(.navText)
                    .navField()
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title3)
                        .foregroundColor(.navAccent)
                        .frame(width: 46, height: 42)
                        .background(Color.navSurface)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.navBorder, lineWidth: 1))
                }
            }
            TextField("端口（默认 9696）", text: $port)
                .keyboardType(.numberPad)
                .foregroundColor(.navText)
                .navField()
            TextField("房间号 room（扫码自动带出）", text: $room)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.navText)
                .navField()
            SecureField("连接密码（未设置则留空）", text: $password)
                .foregroundColor(.navText)
                .navField()

            NavPrimaryButton(title: "连接桌面端",
                             loading: store.connState == .connecting,
                             disabled: host.isEmpty || room.isEmpty) {
                store.connect(host: host, port: port, room: room, password: password)
            }

            if store.connState == .failed {
                errorCard("连接失败：请确认手机与电脑在同一 Wi-Fi、桌面端已开启手机互联、IP/端口/房间号正确。")
            }
        }
    }
}

// MARK: - 云端中继

extension ConnectView {

    private var cloudForm: some View {
        VStack(spacing: 14) {
            infoCard("桌面端开启「云端中继」后，设备会出现在下方列表；点选设备并输入 6 位访问码即可配对，无需同一 Wi-Fi。")

            if store.connState == .connecting && store.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(.navAccent)
                    Text("正在获取在线设备…").foregroundColor(.navMuted)
                }
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(Color.navSurface)
                .cornerRadius(12)
            } else if store.hosts.isEmpty {
                Text("暂无在线设备\n请先在桌面端开启云端中继")
                    .font(.footnote)
                    .foregroundColor(.navMuted)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .background(Color.navSurface)
                    .cornerRadius(12)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.hosts) { host in
                        Button {
                            selectedHost = host
                            code = ""
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundColor(.navAccent)
                                Text(host.name).foregroundColor(.navText)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.navMuted)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(Color.navSurface)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.navBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let host = selectedHost {
                VStack(spacing: 10) {
                    HStack {
                        Text("配对：\(host.name)").font(.footnote).foregroundColor(.navMuted)
                        Spacer()
                        Button { selectedHost = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.navMuted)
                        }
                    }
                    TextField("6 位访问码", text: $code)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.title2)
                        .tracking(8)
                        .foregroundColor(.navText)
                        .navField()
                    NavPrimaryButton(title: "配对",
                                     disabled: code.count < 6) {
                        store.bindHost(hostId: host.id, code: code)
                    }
                }
                .padding(14)
                .background(Color.navSurface2)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.navBorder, lineWidth: 1))
            }

            if !store.bindError.isEmpty {
                errorCard(store.bindError)
            }
        }
    }

    // MARK: - 通用小组件

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.navMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.navSurface.opacity(0.7))
            .cornerRadius(10)
    }

    private func errorCard(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.navRed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.navRed.opacity(0.12))
            .cornerRadius(10)
    }

    /// 桌面端二维码内容: http://<ip>:<port>/?room=<roomId>
    private func parseScanned(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https",
              let h = url.host else {
            return
        }
        host = h
        port = url.port.map(String.init) ?? "9696"
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let r = comps.queryItems?.first(where: { $0.name == "room" })?.value, !r.isEmpty {
            room = r
        }
        tab = .lan
    }
}
