import SwiftUI

struct IOCompanionRoot: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var hideTabBar = false
    @State private var didApplyLaunchTab = false

    var body: some View {
        Group {
            switch store.selectedTab {
            case 1: IOAIView()
            case 2: IONavigationView()
            case 3: IONotebooksView()
            case 4: IOSettingsView()
            default: NavigationStack { IODashboardView() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !hideTabBar {
                HStack(spacing: 0) {
                    tab(0, title: "仪表", icon: "square.grid.2x2")
                    tab(1, title: "AI", icon: "sparkles")
                    tab(2, title: "导航", icon: "location.north.line")
                    tab(3, title: "笔记", icon: "note.text")
                    tab(4, title: "设置", icon: "gearshape")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 3)
                .background(.white)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.line).frame(height: 0.5)
                }
            }
        }
        .onPreferenceChange(CompanionTabBarHiddenPreference.self) { hideTabBar = $0 }
        .onAppear {
            guard !didApplyLaunchTab else { return }
            didApplyLaunchTab = true
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--io-tab"),
                  arguments.indices.contains(flag + 1),
                  let index = Int(arguments[flag + 1]), (0...4).contains(index) else { return }
            store.selectedTab = index
        }
    }

    private func tab(_ index: Int, title: String, icon: String) -> some View {
        Button {
            hideTabBar = false
            store.selectedTab = index
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 11, weight: store.selectedTab == index ? .semibold : .regular))
            }
            .foregroundStyle(store.selectedTab == index ? Palette.green : Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("io-tab-\(index)")
        .accessibilityLabel(title)
        .accessibilityAddTraits(store.selectedTab == index ? .isSelected : [])
    }
}

private struct IOAIView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @State private var showServices = false
    @State private var confirmStart = false
    @State private var continuous = true

    var body: some View {
        Screen(title: "AI", eyebrow: "眼镜语音 · DeepSeek") {
            Card {
                Label(runtime.enabled ? runtime.phaseLabel : "语音待命已关闭",
                      systemImage: runtime.enabled ? "waveform" : "mic.slash")
                    .font(.headline)
                Text(runtime.ready ? "眼镜已连接" : "请先在设置中连接眼镜")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if runtime.enabled {
                    Button("关闭语音待命", role: .destructive) { runtime.stop() }
                        .accessibilityIdentifier("io-voice-stop")
                    Button("结束本轮对话") { runtime.endRound() }
                } else {
                    Toggle("允许连续对话和插话", isOn: $continuous)
                    Button("开启眼镜语音待命") { confirmStart = true }
                        .disabled(!runtime.supportsDevice || !runtime.ready || !runtime.hasCredentials)
                        .accessibilityIdentifier("io-voice-start")
                }
                Text("开启后等待你唤醒眼镜。唤醒后的音频发送到所配置的语音识别服务，文字交给 DeepSeek。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }

            Card {
                Label("你说的话", systemImage: "quote.bubble").font(.headline)
                Text(runtime.transcript.isEmpty ? "识别到的文字会显示在这里。" : runtime.transcript)
                    .textSelection(.enabled).privacySensitive()
                Divider()
                Label("AI 回答", systemImage: "sparkles").font(.headline)
                Text(runtime.answer.isEmpty ? "连接并开启语音后，回答会显示在这里。" : runtime.answer)
                    .textSelection(.enabled).privacySensitive()
                if runtime.modelComplete {
                    Text("回答已生成，眼镜显示效果需在镜片上确认。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }

            Card {
                Button("配置 AI 与语音服务") { showServices = true }
                    .disabled(runtime.enabled)
                    .accessibilityIdentifier("io-ai-services")
                NavigationLink("查看 AI 会话记录") { ConversationTimelineView() }
                Button("清除当前屏幕文字") { runtime.clearText() }
                    .font(.footnote)
            }
            if !runtime.supportsDevice {
                Text("此构建仅支持手机本地功能，未启用眼镜通信。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = runtime.error {
                Text(error).font(.caption).foregroundStyle(Palette.amber)
            }
        }
        .sheet(isPresented: $showServices) { IOAIServiceSettings() }
        .confirmationDialog("开启本次语音待命？唤醒后会使用你配置的云服务，可能产生用量费用。", isPresented: $confirmStart) {
            Button("开启待命") { runtime.start(cloud: true, continuous: continuous) }
        }
    }
}

private struct IONavigationView: View {
    var body: some View {
        Screen(title: "导航", eyebrow: "前往目的地，抬眼看方向") {
            Card {
                Image(systemName: "location.north.line")
                    .font(.system(size: 38, weight: .light)).foregroundStyle(Palette.green)
                Text("眼镜导航尚未启用").font(.title3.weight(.semibold))
                Text("这一版先验证独立连接。高德路线规划和眼镜转向提示将在后续接入。")
                    .foregroundStyle(Palette.muted)
                Text("目前不会启动导航、读取位置或向眼镜发送路线。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct IOSettingsView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @State private var showServices = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { IOConnectionView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("我的眼镜")
                                Text(runtime.ready ? "已认证连接" : "尚未连接")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "eyeglasses") }
                    }.accessibilityIdentifier("io-connection-settings")
                }
                Section("服务") {
                    Button { showServices = true } label: {
                        Label("AI 与语音服务", systemImage: "sparkles")
                    }.disabled(runtime.enabled)
                    NavigationLink { QWeatherDashboardView() } label: {
                        Label("天气服务", systemImage: "cloud.sun")
                    }
                }
                Section("本机资料") {
                    NavigationLink { ReminderImportView() } label: {
                        Label("导入系统提醒事项", systemImage: "checklist")
                    }
                    NavigationLink { TodoView() } label: {
                        Label("管理待办", systemImage: "checkmark.circle")
                    }
                }
                Section("关于 IO伴侣") {
                    LabeledContent("版本", value: appVersion)
                    Text("独立 App · 当前版本用于连接和功能验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("打开 App 不会自动扫描、配对或开始收音。密钥保存在本机钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("构建信息") {
                        Text("IO-COMPANION-DEV01").font(.caption.monospaced()).textSelection(.enabled)
                        Text(runtime.supportsDevice ? "已包含眼镜连接模块；实际连接需在设备上确认。" : "未包含眼镜连接模块。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
        }
        .sheet(isPresented: $showServices) { IOAIServiceSettings() }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未标注"
        let build = info?["CFBundleVersion"] as? String ?? "未标注"
        return "\(version) (\(build))"
    }
}

private struct IOConnectionView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures

    var body: some View {
        Form {
            Section("连接") {
                Label(runtime.ready ? "眼镜已认证连接" : "尚未连接眼镜",
                      systemImage: runtime.ready ? "checkmark.circle" : "eyeglasses")
                Button("发现附近可配对的眼镜") { runtime.discover() }
                    .disabled(!runtime.supportsDevice || runtime.enabled || runtime.ready)
                    .accessibilityIdentifier("io-discover")
                Button("连接唯一发现的眼镜") { runtime.connect() }
                    .disabled(!runtime.supportsDevice || runtime.enabled || runtime.ready)
                    .accessibilityIdentifier("io-pair")
                Button("重连本 App 已绑定眼镜") { runtime.reconnectBonded() }
                    .disabled(!runtime.supportsDevice || runtime.enabled)
                    .accessibilityIdentifier("io-reconnect")
                Text("首次连接需让眼镜进入可配对状态。有多副眼镜时不会自动替你选择；此页不执行解绑或重置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("眼镜状态") {
                LabeledContent("电量", value: batteryLabel)
                LabeledContent("固件版本", value: "尚未提供回读")
                Button("读取眼镜状态") { features.refreshSettings() }
                    .disabled(!runtime.ready || runtime.enabled)
                    .accessibilityIdentifier("io-read-device-status")
                Text(features.status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = features.error ?? runtime.error {
                Section("操作提示") { Text(error).font(.caption).foregroundStyle(Palette.amber) }
            }
            Section {
                DisclosureGroup("连接诊断") {
                    Text(runtime.latestEvent)
                        .font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                    Text("已连接仅表示通信认证成功；每项眼镜功能仍需分别确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("我的眼镜")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var batteryLabel: String {
        guard runtime.ready, let value = features.battery, (0...100).contains(value) else { return "尚未读取" }
        return "\(value)%"
    }
}

private struct IOAIServiceSettings: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var asrHost = CloudASRHostSettings.current()
    @State private var asrKey = ""
    @State private var modelKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("语音识别") {
                    TextField("阿里云 ASR Host（不含 https://）", text: $asrHost)
                        .keyboardType(.URL).accessibilityIdentifier("io-asr-host")
                    SecureField("API Key（留空保留）", text: $asrKey)
                        .accessibilityIdentifier("io-asr-key")
                    Text("需要支持当前流式语音识别接口的服务。语音识别与 DeepSeek 使用各自的密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("DeepSeek") {
                    SecureField("DeepSeek API Key（留空保留）", text: $modelKey)
                        .accessibilityIdentifier("io-deepseek-key")
                    Text("当前语音链路使用 DeepSeek 官方服务。保存不会开始收音或发送对话。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("保存配置") {
                        let saved = runtime.saveKeys(asr: asrKey, llm: modelKey, host: asrHost, enableDefault: false)
                        asrKey = ""; modelKey = ""
                        if saved { dismiss() }
                    }
                    .disabled(!runtime.supportsDevice || runtime.enabled)
                    .accessibilityIdentifier("io-save-ai-services")
                    Text("密钥只存入本机钥匙串，不显示已有值。保存后请到 AI 页手动开启语音待命。")
                        .font(.caption).foregroundStyle(.secondary)
                    if runtime.enabled { Text("请先在 AI 页关闭语音待命，再修改服务。") }
                    if !runtime.supportsDevice { Text("此构建未启用眼镜语音服务配置。") }
                    if let error = runtime.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .navigationTitle("AI 与语音服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .onDisappear { asrKey = ""; modelKey = "" }
    }
}
