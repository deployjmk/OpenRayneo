// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

private enum ControlPage: String, CaseIterable, Identifiable {
    case setup = "Devices & API", navigation = "Navigation demo", video = "Character video", text = "Text display", notification = "Notification", teleprompter = "Teleprompter", audio = "Speech & Recording"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: return "link"
        case .navigation: return "arrow.turn.up.right"
        case .video: return "film"
        case .text: return "text.bubble"
        case .notification: return "bell"
        case .teleprompter: return "doc.text"
        case .audio: return "waveform"
        }
    }
}

@MainActor
private struct DesktopControlView: View {
    @ObservedObject var bridge: DesktopBridge
    @State private var page: ControlPage = .setup
    @State private var direction: NavigationDirection = .uturn
    @State private var meters = 100
    @State private var videoStyle: TextVideoStyle = .fullWidth
    @State private var videoFPS = 10
    @State private var invertVideo = false
    @State private var enhanceVideoContrast = false
    @State private var alignVideoUpdates = true
    @State private var caption = "Hello, OpenRayneo.\nThis text comes from the Mac control panel."
    @State private var answer = ""
    @State private var usePrompt = true
    @State private var notificationTitle = "OpenRayneo"
    @State private var notificationBody = "Notification from your Mac"
    @State private var scriptTitle = "My script"
    @State private var scriptText = ""
    @State private var scriptSpeed = 60
    @State private var locale = "zh-CN"
    @State private var audioDuration = 60
    @State private var saveAudio = false
    @State private var saveLifeLogAudio = true

    private var unavailable: Bool { bridge.busy || bridge.stopping }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.rawValue).font(.title2.weight(.semibold))
                        Text(bridge.activeSession.map { "Active session: \($0.title)" } ?? "Ready to send to the glasses")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bridge.activeSession != nil {
                        Button("End session", systemImage: "stop.fill") { bridge.stopSession() }.disabled(unavailable)
                    }
                }
                if let error = bridge.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled).font(.callout)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .setup: setupPanel
                        case .navigation: navigationPanel
                        case .video: videoPanel
                        case .text: textPanel
                        case .notification: notificationPanel
                        case .teleprompter: teleprompterPanel
                        case .audio: audioPanel
                        }
                        connectionHelp
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if bridge.busy || bridge.stopping { ProgressView().controlSize(.small) }
                    Text(bridge.notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.frame(minHeight: 24)
            }.padding(24)
        }.frame(minWidth: 900, minHeight: 630)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("OpenRayneo", systemImage: "eyeglasses").font(.title3.weight(.semibold))
            HStack(spacing: 7) {
                Circle().fill(bridge.connected ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                Text(bridge.phase).font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(bridge.refreshingDevices ? "Reading paired devices…" : "Paired glasses").font(.caption).foregroundStyle(.secondary)
                Picker("Glasses", selection: $bridge.selectedAddress) {
                    if bridge.devices.isEmpty { Text("No glasses found").tag("") }
                    ForEach(bridge.devices) { Text("\($0.name) · \($0.id.suffix(5))").tag($0.id) }
                }.labelsHidden().disabled(bridge.serviceRunning || unavailable)
                HStack {
                    Button("Refresh", systemImage: "arrow.clockwise") { bridge.refreshDevices() }
                        .disabled(bridge.serviceRunning || bridge.refreshingDevices || unavailable)
                    Button("Bluetooth Settings") { bridge.openBluetoothSettings() }
                }.controlSize(.small)
                Button("Add & Pair Glasses") { page = .setup; bridge.pairAndConnect() }
                    .disabled(unavailable || bridge.refreshingDevices)
                if bridge.serviceRunning {
                    if !bridge.connected {
                        Button("Reconnect") { bridge.connect() }.disabled(unavailable)
                    }
                    Button(bridge.stopping ? "Disconnecting…" : "Disconnect") { bridge.disconnect() }.disabled(bridge.stopping)
                } else {
                    Button("Connect Glasses") { bridge.connect() }
                        .buttonStyle(.borderedProminent).disabled(bridge.selectedAddress.isEmpty || unavailable)
                }
            }
            Button(bridge.activeSession == .prompts ? "Re-enter Microphone Mode" : "Enter Microphone Mode", systemImage: "mic") {
                bridge.enterMicrophoneMode()
            }.disabled(unavailable || bridge.selectedAddress.isEmpty)
            if bridge.microphoneForwarding {
                Label(bridge.microphoneRecovering ? "Microphone recovering" : bridge.microphoneAudioState == "waiting" ? "Waiting for glasses audio" : "Both microphones active", systemImage: "mic.fill").font(.caption)
                Text(String(format: "Audio received: %.1f s", bridge.audioSeconds))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Divider()
            ForEach(ControlPage.allCases) { item in
                Button { page = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 10)
                        .background(page == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            Spacer()
            Text("If your phone holds the connection, turn off the phone Bluetooth first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 240).frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            setupStep(number: 1, title: "Discover & pair", complete: bridge.verifiedPairingAddress == bridge.selectedAddress,
                      detail: bridge.selectedDevice.map { "Selected \($0.name)" } ?? "Put the glasses in pairing mode, then click the button below to discover and pair.")
            HStack {
                Button("Add & Pair Glasses", systemImage: "plus") { bridge.pairAndConnect() }
                    .disabled(unavailable || bridge.refreshingDevices)
                Text("Removes the glasses old Mac pairing, then pairs and enables the API.").font(.caption).foregroundStyle(.secondary)
            }
            if bridge.pairingActive {
                Text("Keep the glasses powered on and the phone Bluetooth off. After starting, do not remove the Mac pairing or re-enter the glasses pairing mode; if a number appears, verify it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel pairing") { bridge.cancelPairing() }
                }
            }
            Divider()
            setupStep(number: 2, title: "Connect the glasses", complete: bridge.connected,
                      detail: bridge.connected ? "Bluetooth authentication and the data channel are established." : "A paired glasses connects directly; the background service and auth token are prepared automatically.")
            Button(bridge.connected ? "Connected" : "Connect & Enable API", systemImage: "bolt.horizontal") { bridge.connect() }
                .buttonStyle(.borderedProminent).disabled(bridge.connected || bridge.selectedAddress.isEmpty || unavailable)
            Button(bridge.restartingService ? "Restarting connection service…" : "Restart Connection Service", systemImage: "arrow.clockwise") {
                bridge.restartConnectionService()
            }
            .disabled(bridge.selectedAddress.isEmpty || bridge.stopping || bridge.restartingService || bridge.pairingActive || bridge.refreshingDevices)
            Text("Restart the service if the connection stalls; the window stays open and the system pairing is kept. Active display or recording sessions end, and the API address and token may change.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            microphoneSettings
            Divider()
            setupStep(number: 3, title: "Local API", complete: bridge.apiReady,
                      detail: bridge.apiReady ? "Health check and token-authenticated device query passed." : bridge.serviceRunning ? "Service started; waiting for the glasses to connect or for the API check." : "After connecting, you can copy the address and the call command.")
            if bridge.serviceRunning {
                Text(bridge.apiAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy Address") { bridge.copyAPIAddress() }
                    Button("Copy Token") { bridge.copyAPIToken() }
                    Button("Check API") { bridge.checkAPI() }.disabled(unavailable)
                }
                Text(bridge.apiExample).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                Button("Copy token-authenticated call example", systemImage: "doc.on.doc") { bridge.copyAPIExample() }
                if let verified = bridge.apiVerifiedAt {
                    Text("Last check: \(verified.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("The API is for this Mac only. The service stops on disconnect or quit; after reconnecting, use the current address and token.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setupStep(number: Int, title: String, complete: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2).foregroundStyle(complete ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var navigationPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Minimal character navigation").font(.headline)
            Text("Simulates turns and distance; no map or GPS yet.").foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Picker("Direction", selection: $direction) {
                    ForEach(NavigationDirection.allCases) { Text($0.title).tag($0) }
                }.frame(width: 180)
                Stepper(value: $meters, in: 0...9990, step: 10) {
                    Text(meters == 0 ? "Turn now" : "Distance: \(meters) m").monospacedDigit()
                }
            }
            let cells = NavigationFrame.rows(direction: direction, meters: meters).flatMap { Array($0) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 0), count: 20), spacing: 0) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(String(cells[index])).font(.system(size: 16, weight: .regular, design: .monospaced)).frame(width: 16, height: 20)
                }
            }.padding(20).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            Text("20×5 layout preview; the glasses render the actual font.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(bridge.activeSession == .navigation ? "Update navigation" : "Show navigation", systemImage: "paperplane") {
                    bridge.showNavigation(direction: direction, meters: meters)
                }.buttonStyle(.borderedProminent)
                Button("Reopen Display") { bridge.showNavigation(direction: direction, meters: meters, reopen: true) }
            }.disabled(unavailable || bridge.selectedAddress.isEmpty)
            Text("First-row auto-alignment: no correction on first display; later refreshes auto-correct.").font(.caption).foregroundStyle(.secondary)
            Text("After manually exiting on the glasses, use \"Reopen Display\".").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Display page", selection: $usePrompt) {
                Text("Live captions").tag(false)
                Text("Live prompts").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 340)
            Text(usePrompt ? "Prompt title" : "Text to display").font(.headline)
            editor($caption, height: usePrompt ? 80 : 170)
            if usePrompt {
                Text("Answer body").font(.headline)
                editor($answer, height: 120)
                Text(bridge.builtInMicrophonesReady ? "Live Prompts relays both microphones by default; updating the answer does not interrupt audio." : "After installing the built-in driver, Live Prompts relays both microphones.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Send to Glasses", systemImage: "paperplane") { bridge.showText(caption, translation: answer, prompt: usePrompt) }
                    .buttonStyle(.borderedProminent)
                Button("Reopen Display") { bridge.showText(caption, translation: answer, prompt: usePrompt, reopen: true) }
            }.disabled(unavailable || caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.selectedAddress.isEmpty)
        }
    }

    private var videoPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn local video into character animation on the glasses").font(.headline)
            Text("Works with black-and-white silhouette videos such as Bad Apple. Uses 26×7 full-width character cells, silent playback; the initial version supports up to 10 minutes.").foregroundStyle(.secondary)
            HStack {
                Button("Choose Video…", systemImage: "folder") { bridge.chooseVideo() }
                    .disabled(unavailable || bridge.videoImporting || bridge.videoPlaying)
                if bridge.videoImporting {
                    ProgressView().controlSize(.small)
                    Button("Cancel Decode") { bridge.cancelVideoImport() }
                }
                Button("Check Character Alignment") { bridge.showVideoAlignment() }
                    .disabled(unavailable || bridge.selectedAddress.isEmpty)
                Button("End Display", systemImage: "stop.fill") { bridge.stopSession() }
                    .disabled(unavailable || bridge.activeSession != .video)
            }
            Text("The alignment ruler contains blocks, blanks, full-width letters, and punctuation. Confirm that the left and right lines of the seven rows align before playing the video.").font(.caption).foregroundStyle(.secondary)
            if let video = bridge.textVideo {
                Text("\(video.name) · \(Int(video.duration)) s").textSelection(.enabled)
                HStack {
                    Picker("Characters", selection: $videoStyle) {
                        ForEach(TextVideoStyle.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 250)
                    Picker("Frame rate", selection: $videoFPS) {
                        Text("5 fps").tag(5)
                        Text("10 fps").tag(10)
                    }.frame(width: 170)
                }.disabled(bridge.videoPlaying)
                Toggle("Invert black & white", isOn: $invertVideo).disabled(bridge.videoPlaying)
                Toggle("Boost contrast", isOn: $enhanceVideoContrast).disabled(bridge.videoPlaying)
                Toggle("Pad first row by one cell on refresh", isOn: $alignVideoUpdates).disabled(bridge.videoPlaying)
                Text("Full-width grayscale picks characters by region brightness, using full-width spaces as blanks. Brightness is calibrated for the PingFang font; glyphs and alignment on the glasses follow the ruler.").font(.caption).foregroundStyle(.secondary)
                let preview = bridge.videoSeconds > 0 || bridge.videoPlaying ? bridge.videoPreview : video.frames[0].text(style: videoStyle, inverted: invertVideo, enhanceContrast: enhanceVideoContrast)
                Text(preview).font(.custom("PingFangSC-Regular", size: 14)).lineSpacing(0)
                    .padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                ProgressView(value: min(bridge.videoSeconds, video.duration), total: video.duration)
                Text("\(Int(bridge.videoSeconds)) / \(Int(video.duration)) s").font(.caption).monospacedDigit()
                HStack {
                    Button("Play from start on glasses", systemImage: "play.fill") {
                        bridge.playVideo(style: videoStyle, fps: videoFPS, inverted: invertVideo, alignUpdates: alignVideoUpdates, enhanceContrast: enhanceVideoContrast)
                    }.buttonStyle(.borderedProminent)
                        .disabled(unavailable || bridge.videoImporting || bridge.videoPlaying || bridge.selectedAddress.isEmpty)
                }
                Text("Frames are skipped when the link cannot keep up — no backlog. After playback the last frame sent stays on the glasses; click \"End Display\" to exit.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Notification title", text: $notificationTitle).textFieldStyle(.roundedBorder)
            editor($notificationBody, height: 150)
            Button("Send Notification", systemImage: "bell.badge") { bridge.notify(title: notificationTitle, body: notificationBody) }
                .buttonStyle(.borderedProminent)
                .disabled(unavailable || notificationBody.isEmpty || bridge.selectedAddress.isEmpty)
        }
    }

    private var teleprompterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Script title", text: $scriptTitle).textFieldStyle(.roundedBorder)
            editor($scriptText, height: 220)
            Picker("Scroll speed", selection: $scriptSpeed) {
                Text("60").tag(60)
                Text("120").tag(120)
            }.frame(width: 180)
            HStack {
                Button("Send & Play", systemImage: "play.fill") { bridge.startTeleprompter(title: scriptTitle, text: scriptText, speed: scriptSpeed) }
                    .buttonStyle(.borderedProminent).disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.selectedAddress.isEmpty)
                Button("Pause") { bridge.controlTeleprompter("pause") }.disabled(bridge.activeSession != .teleprompter)
                Button("Resume") { bridge.controlTeleprompter("resume") }.disabled(bridge.activeSession != .teleprompter)
            }.disabled(unavailable)
        }
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use the glasses microphone directly").font(.headline)
            Text("Recognizes Chinese or English locally; recordings are saved as two-channel WAV. Starting replaces the current Live Prompts session.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Picker("Language", selection: $locale) { Text("Chinese").tag("zh-CN"); Text("English").tag("en-US") }.frame(width: 200)
                Picker("Duration", selection: $audioDuration) { Text("1 minute").tag(60); Text("3 minutes").tag(180); Text("5 minutes").tag(300); Text("10 minutes").tag(600) }.frame(width: 180)
            }
            Toggle("Also save the recording while recognizing", isOn: $saveAudio)
            HStack {
                Button("Start Speech Recognition", systemImage: "waveform") { bridge.startAudio(recognize: true, record: saveAudio, duration: audioDuration, locale: locale) }
                    .buttonStyle(.borderedProminent)
                Button("Record Only", systemImage: "record.circle") { bridge.startAudio(recognize: false, record: true, duration: audioDuration, locale: locale) }
            }.disabled(unavailable || bridge.selectedAddress.isEmpty || (bridge.activeSession == .asr || bridge.activeSession == .recording))
            if bridge.activeSession?.isAudio == true || bridge.audioSeconds > 0 {
                Text(String(format: "Audio received: %.1f s", bridge.audioSeconds)).monospacedDigit()
            }
            if !bridge.transcript.isEmpty {
                Text(bridge.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            if let path = bridge.recordingPath {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bridge.recordingFinalized ? "Recording saved" : "Writing recording file").font(.headline)
                    Text(path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder") { bridge.revealRecording() }
                        Button("Play Recording") { bridge.playRecording() }.disabled(!bridge.recordingFinalized)
                    }
                }
            }
            Divider()
            Text("All-day log audio (experimental)").font(.headline)
            Text("Stops automatically after the duration above; audio can be saved and replayed. Current hardware delivers mono and does not replace the two virtual microphones yet; audio may not upload when no voice is present.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Save mono WAV for playback", isOn: $saveLifeLogAudio)
                .disabled(bridge.activeSession == .lifeLog)
            HStack {
                Button("Start all-day log capture") { bridge.startLifeLog(duration: audioDuration, record: saveLifeLogAudio) }
                    .disabled(unavailable || bridge.selectedAddress.isEmpty || bridge.activeSession == .lifeLog)
                Button("Trigger one audio round") { bridge.triggerLifeLogAudio() }
                    .disabled(unavailable || bridge.activeSession != .lifeLog)
                Button("Stop all-day log") { bridge.stopSession() }
                    .disabled(unavailable || bridge.activeSession != .lifeLog)
            }
            if bridge.activeSession == .lifeLog || bridge.lifeLogSeconds > 0 {
                Text(String(format: "Audio decoded: %.1f s", bridge.lifeLogSeconds)).monospacedDigit()
                Text(bridge.lifeLogChannels).font(.callout)
                if bridge.lifeLogDecodeErrors > 0 {
                    Text("Decode failed: \(bridge.lifeLogDecodeErrors) frames").foregroundStyle(.orange)
                }
            }
            Text("Channel 1: bone-conduction mic, captures your own voice. Channel 2: forward mic, captures others. ASR currently recognizes both channels mixed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glasses microphone").font(.headline)
            Text("After connecting, both microphones turn on by default and the Live Prompts page opens; question and answer can be shown together.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Label(bridge.builtInMicrophonesReady ? "Both built-in microphones ready" : "Built-in microphone not installed", systemImage: bridge.builtInMicrophonesReady ? "checkmark.circle" : "mic")
                Button("Refresh Devices") { bridge.refreshVirtualAudioDevices() }
                    .disabled(unavailable || bridge.microphoneForwarding)
                Button(bridge.builtInMicrophonesReady ? "Reinstall Driver…" : "Install Built-in Driver…") {
                    bridge.openVirtualMicrophoneInstaller()
                }.disabled(unavailable || bridge.activeSession?.isAudio == true)
            }
            Picker("Microphone auto-stop", selection: $bridge.microphoneDuration) {
                Text("10 minutes").tag(600)
                Text("1 hour").tag(3_600)
                Text("6 hours").tag(21_600)
            }.frame(width: 280).disabled(bridge.microphoneForwarding)
            Text("OpenRayneo Microphone Channel 1: your own voice; Channel 2: sounds in front of you.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Open Sound Settings") { bridge.openSoundSettings() }
                Button("Restore Audio Output") { bridge.recoverMicrophoneOutput() }
                    .disabled(unavailable || bridge.activeSession != .prompts || !bridge.microphoneForwarding)
                if bridge.microphoneForwarding {
                    Text(bridge.microphoneRecovering ? "Audio devices unavailable, recovering" : bridge.microphoneAudioState == "waiting" ? "Waiting for the glasses to upload audio; page stays open" : "Relaying both audio channels").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("If entering fails or you exit on the glasses, click \"Enter / Re-enter Microphone Mode\" on the left. Switching system audio devices restores output automatically and keeps the glasses page; you can also restore audio output manually. Relaying neither records nor recognizes; switching to captions, video, or the teleprompter pauses it. It ends normally at the auto-stop time or when you click \"End session\".")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { bridge.refreshVirtualAudioDevices() }
    }

    private var connectionHelp: some View {
        DisclosureGroup("Connection help & diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                Text("First use: put the glasses in pairing mode and click \"Add & Pair Glasses\". The app first removes the glasses old Mac pairing, confirms they are unpaired and disconnected, then creates a new pairing.")
                Text("For everyday use with an existing pairing, choose \"Connect Glasses\". To re-pair, put the glasses in pairing mode and click \"Add & Pair Glasses\"; if the system cannot auto-remove the old pairing, remove it manually as the error suggests.")
                Button("Open Bluetooth Settings") { bridge.openBluetoothSettings() }
                if let pid = bridge.serviceProcessID { Text("Connection service PID: \(pid)").textSelection(.enabled) }
                if !bridge.apiAddress.isEmpty {
                    Text("Local API: \(bridge.apiAddress)").textSelection(.enabled)
                    Button("Copy API Token") { bridge.copyAPIToken() }
                }
                if !bridge.diagnostics.isEmpty { Text(bridge.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).padding(8).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
    }
}

@MainActor
private final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    private let bridge = DesktopBridge()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit OpenRayneo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenRayneo"
        window.contentView = NSHostingView(rootView: DesktopControlView(bridge: bridge))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        bridge.refreshDevices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.cancelPairing()
        Task { let stopped = await bridge.shutdown(); sender.reply(toApplicationShouldTerminate: stopped) }
        return .terminateLater
    }
}

@MainActor
func runDesktopApplication() -> Never {
    let app = NSApplication.shared
    let delegate = DesktopApplicationDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}
