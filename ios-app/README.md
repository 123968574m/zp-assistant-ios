# ZP助手 iOS 客户端（IPA）

把桌面端「手机互联」的手机网页版做成原生 iOS 应用（**领航者**），企业签名分发安装。

支持两种连接模式：
- **局域网 · 扫码**：扫码/手填直连桌面端（同一 Wi-Fi）
- **云端 · 非局域网**：连接中继 `navway.cc.cd`，在线设备列表 + 6 位访问码配对，跨网络使用

- **ZP助手悬浮球**：连接后常驻的可拖动悬浮球，点开展开半透明面板，**实时显示桌面端生成的提示词**（AI 回答流式追加、自动滚到底部、字号可调、生成中有黄点提示）
- 扫码或手填连接桌面端（IP / 端口 / 房间号 / 密码）
- 会话页显示当前模式 / 模型 / 提示词全文
- 远程控制按钮：截图、切换模式、停止生成、清空文字、语音对话（按桌面端功能开关显隐）

## 一、目录结构

```
ios-app/
├── project.yml                    # XcodeGen 工程定义
├── ExportOptions-enterprise.plist # 企业签名导出配置（本地 Mac 打包用）
├── build-ipa.sh                   # 备选：Mac 本地一键出包脚本
├── .gitignore                     # 云构建时忽略生成产物
├── README.md
└── ZPAssistant/                   # Swift 源码
    ├── ZPAssistantApp.swift       # 入口 + 根视图（连接页/会话页切换）
    ├── SessionStore.swift         # Socket.IO 连接与状态（协议同手机网页版）
    ├── ConnectView.swift          # 连接页（扫码/手填）
    ├── SessionView.swift          # 会话主界面
    ├── AssistantBubble.swift      # ZP助手悬浮球 + 提示词面板
    └── QRScannerView.swift        # 二维码扫描
```

## 二、出包路线 A：GitHub Actions 云构建（推荐，Windows 无需 Mac）

云端 macOS 机器编译出**未签名 IPA**，你在 Windows 上企业重签后安装。

1. 把项目推到 GitHub（本目录已带 `.github/workflows/build-ios.yml`）：

   ```bash
   git init
   git add ios-app .github
   git commit -m "ZP助手 iOS 工程"
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

2. GitHub 仓库页 → **Actions** → 左侧 **Build iOS IPA** → **Run workflow** 手动触发（或推一个 `ios-v1` 标签自动触发）。

3. 构建完成后在该次运行的 **Artifacts** 里下载 `ZPAssistant-unsigned-ipa`，解压得到 `ZPAssistant-unsigned.ipa`。

说明：
- workflow 使用 `macos-14` runner，首次构建会自动拉取 socket.io-client-swift 依赖（SPM），大约 5-10 分钟。
- **公开仓库** macOS runner 免费；**私有仓库** macOS 按 10 倍时长计费（免费额度会很快用完），介意费用就把仓库设为公开，或只放 ios-app 子目录到公开仓库。

## 三、企业重签名（Windows 上做）

拿到的 `ZPAssistant-unsigned.ipa` 没有签名，用你的企业证书二选一重签：

**方式 1：爱思助手（图形界面，最简单）**

1. 爱思助手 → 工具箱 → IPA 签名
2. 选择 `ZPAssistant-unsigned.ipa`
3. 导入企业证书 `.p12` + 对应的 `.mobileprovision` 描述文件
4. 签名 → 得到已签名 ipa → 安装到手机

**方式 2：zsign（命令行）**

在 Windows 的 WSL / 任意 Linux / macOS 上：

```bash
zsign -k enterprise.p12 -p "p12密码"       -m embedded.mobileprovision       -o ZPAssistant-signed.ipa       ZPAssistant-unsigned.ipa
```

签名完成后安装：蒲公英/fir.im 上传链接安装、itms-services OTA、或爱思助手 USB 安装。首次打开需在手机 设置 → 通用 → VPN与设备管理 里信任企业证书。

## 四、出包路线 B（备选）：Mac 本地打包

如果某台 Mac 可用（企业签名导出为正式签名 IPA，无需再重签）：

```bash
brew install xcodegen
cd ios-app
TEAM_ID=你的企业证书TeamID ./build-ipa.sh
# 产物: ios-app/build/ZPAssistant.ipa
```

## 五、桌面端配合

1. 桌面端打开 设置 → 手机互联 → 启用（LAN 模式，默认端口 9696）
2. 桌面端窗口会显示二维码，App 里点右上角扫码即自动填入连接信息
3. 若设置了连接密码，App 里手动输入一次（原生客户端无法从二维码拿到密码，桌面端已兼容 query 传密码）
4. 手机与电脑必须在**同一局域网**（云端中继模式暂不支持原生 App，仍用网页版）

## 六、系统级悬浮（视频通话型画中画）

**ZP助手支持悬浮在系统和任何其它应用之上**，采用 FaceTime 同款的**视频通话型画中画**通道：

1. 会话页右上角点 **PiP 图标**开启悬浮（再次点击关闭；也可在小窗上关闭）
2. 悬浮内容是原生面板，AI 回答实时刷新、自动滚动保留最新内容
3. **与摄像头/视频类应用共存**：通话型画中画属于"通话"槽位，不会被其它 App 的视频播放（如腾讯视频）、相机调用踢掉，也不会出现"禁止播放"按钮（该通道没有播放/暂停控件）
4. 小窗可拖动、双指捏合缩放
5. 后台由静音循环保活；若悬浮窗被系统极端情况终止，App 会在 1 秒内自动重拉（最多 8 次）

## 七、协议对应（与桌面端 src/main/mobile-sync 完全一致）

| 方向 | 事件 | 内容 |
|---|---|---|
| 下行 | `response_mode` | 当前回答模式标签 |
| 下行 | `current_model` | 当前模型标签 |
| 下行 | `feature_sync` | 各控制功能开关 |
| 下行 | `ai_thinking` | 生成开始/结束（开始时清空文本） |
| 下行 | `answer_stream_chunk` | { seq, content } 流式分片 |
| 下行 | `answer_clear` | 清空 |
| 下行 | `answer_resync` | 断线重连后补发全文 { text, nextSeq, thinking } |
| 上行 | `remote_action` | { action: screenshot / switchMode / stopGeneration / clearText / voice / scrollUp / scrollDown / switchModelPrev / switchModelNext } |
| 上行 | `answer_resync` | 客户端请求补发 |
| 握手 | query | `room=<房间号>&password=<密码>`（桌面端已兼容 query 密码） |

注：`scrollUp/scrollDown` 两个动作桌面端当前未映射处理（与网页版行为一致），按钮保留以对齐功能开关。
