// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PairedGlasses: Identifiable, Sendable {
    let id: String
    let name: String
}

enum DesktopSession: String {
    case navigation, video, captions, prompts, teleprompter, asr, recording, lifeLog
    var isAudio: Bool { self == .asr || self == .recording || self == .prompts }
    var stopPath: String {
        switch self {
        case .navigation, .video, .captions: return "/v1/captions/stop"
        case .prompts: return "/v1/prompts/stop"
        case .teleprompter: return "/v1/teleprompter/stop"
        case .asr, .recording: return "/v1/asr/stop"
        case .lifeLog: return "/v1/lifelog/stop"
        }
    }
    var title: String {
        switch self {
        case .navigation: return "Navigation demo"
        case .video: return "Character video"
        case .captions: return "Live captions"
        case .prompts: return "Live prompts"
        case .teleprompter: return "Teleprompter"
        case .asr: return "Speech recognition"
        case .recording: return "Recording"
        case .lifeLog: return "All-day log experiment"
        }
    }
}

private struct DesktopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class DesktopBridge: ObservableObject {
    @Published var devices: [PairedGlasses] = []
    @Published var selectedAddress = ""
    @Published private(set) var connected = false
    @Published private(set) var serviceRunning = false
    @Published private(set) var serviceProcessID: Int32?
    @Published private(set) var restartingService = false
    @Published private(set) var refreshingDevices = false
    @Published private(set) var pairingActive = false
    @Published private(set) var verifiedPairingAddress: String?
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var phase = "Not connected"
    @Published private(set) var notice = "Select a paired glasses and click Connect."
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeSession: DesktopSession? {
        didSet { if activeSession != .navigation { navigationFrameSent = false } }
    }
    @Published private(set) var transcript = ""
    @Published private(set) var audioSeconds = 0.0
    @Published private(set) var lifeLogSeconds = 0.0
    @Published private(set) var lifeLogChannels = "No audio received yet"
    @Published private(set) var lifeLogDecodeErrors = 0
    @Published private(set) var virtualAudioDevices: [VirtualAudioDevice] = []
    @Published private(set) var virtualMicrophoneName: String?
    @Published private(set) var microphoneForwarding = false
    @Published private(set) var microphoneRecovering = false
    @Published private(set) var microphoneAudioState = "stopped"
    @Published var microphoneDuration = 3_600
    var builtInMicrophonesReady: Bool {
        VirtualMicrophone.builtInDeviceUIDs.allSatisfy { uid in virtualAudioDevices.contains { $0.id == uid } }
    }
    @Published private(set) var recordingPath: String?
    @Published private(set) var recordingFinalized = false
    @Published private(set) var apiAddress = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var apiVerifiedAt: Date?
    @Published private(set) var textVideo: TextVideo?
    @Published private(set) var videoImporting = false
    @Published private(set) var videoPlaying = false
    @Published private(set) var videoSeconds = 0.0
    @Published private(set) var videoPreview = ""

    var apiReady: Bool { serviceRunning && connected && apiVerifiedAt != nil }
    var selectedDevice: PairedGlasses? { devices.first { $0.id == selectedAddress } }

    var apiExample: String {
        "curl '\(apiAddress.isEmpty ? "http://127.0.0.1:8765" : apiAddress)/v1/device' \\\n  -H 'Authorization: Bearer <API_TOKEN>'"
    }

    private var service: Process?
    private var navigationFrameSent = false
    private var lastPromptContent: [String: Any]?
    private var videoImport: Task<Void, Never>?
    private var videoPlayback: Task<Void, Never>?
    private let pairing = BluetoothPairing()
    private var token = ""
    private var stderrPipe: Pipe?
    private var stderrText = ""
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var monitor: Task<Void, Never>?
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    func refreshDevices() {
        guard !serviceRunning, !refreshingDevices, !pairingActive else { return }
        refreshingDevices = true
        Task {
            defer { refreshingDevices = false }
            do {
                let found = try await PairedGlasses.systemInventory()
                guard !serviceRunning else { return }
                devices = found
                let preferred = (ProcessInfo.processInfo.environment["RAYNEO_ADDRESS"] ?? UserDefaults.standard.string(forKey: "selectedGlasses"))?.replacingOccurrences(of: ":", with: "-")
                if !devices.contains(where: { $0.id == selectedAddress }) {
                    selectedAddress = devices.first(where: { $0.id == preferred })?.id ?? devices.first?.id ?? ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    func pairAndConnect() {
        guard !busy, !stopping, !refreshingDevices else { return }
        if serviceRunning {
            Task {
                guard await shutdown() else { return }
                self.pairAndConnect()
            }
            return
        }
        perform("Preparing to pair glasses…") {
            self.verifiedPairingAddress = nil
            self.pairingActive = true
            defer { self.pairingActive = false }
            guard let device = try await self.pairing.pair(progress: { phase, notice in
                self.phase = phase
                self.notice = notice
            }) else {
                self.phase = "Pairing cancelled"
                self.notice = "Pairing cancelled; API not started."
                return
            }
            self.devices.removeAll { $0.id == device.id }
            self.devices.append(device)
            self.selectedAddress = device.id
            self.verifiedPairingAddress = device.id
            UserDefaults.standard.set(device.id, forKey: "selectedGlasses")
            self.pairingActive = false
            self.notice = "Pairing complete; connecting and enabling API…"
            try await self.ensureConnected()
            try await self.startDefaultPromptIfIdle()
            self.notice = "Pairing and connection complete; the local API is ready."
        }
    }

    func cancelPairing() {
        pairing.cancel()
        operation?.cancel()
    }

    func connect() {
        perform("Connecting to glasses…") {
            try await self.ensureConnected()
            try await self.startDefaultPromptIfIdle()
        }
    }

    func disconnect() {
        Task { if await shutdown() { notice = "Disconnected; background service stopped." } }
    }

    func restartConnectionService() {
        guard !stopping, !restartingService, !pairingActive, !refreshingDevices, !selectedAddress.isEmpty else { return }
        restartingService = true
        Task {
            defer { restartingService = false }
            guard await shutdown() else { return }
            perform("Restarting connection service…") {
                try await self.ensureConnected()
                try await self.startDefaultPromptIfIdle()
                self.notice = "Connection service restarted; the API is ready. Use the address and token now shown."
            }
        }
    }

    func showNavigation(direction: NavigationDirection, meters: Int, reopen: Bool = false) {
        perform("Sending navigation…") {
            try await self.prepareDisplay(.navigation, reopen: reopen)
            _ = try await self.request("/v1/captions/text", body: NavigationFrame.payload(direction: direction, meters: meters, compensateFirstCell: self.navigationFrameSent))
            self.navigationFrameSent = true
            self.notice = "Navigation sent: \(meters == 0 ? "now" : "in \(meters) m") \(direction.title)"
        }
    }

    func chooseVideo() {
        guard !videoImporting, !videoPlaying, !busy, !stopping else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func loadVideo(_ url: URL) {
        guard !videoImporting, !videoPlaying, !busy, !stopping else { return }
        videoImporting = true
        errorMessage = nil
        notice = "Decoding video: \(url.lastPathComponent)…"
        videoImport = Task {
            defer { videoImporting = false; videoImport = nil }
            do {
                let video = try await TextVideo.load(url)
                try Task.checkCancellation()
                textVideo = video
                videoSeconds = 0
                videoPreview = video.frames[0].text(style: .fullWidth, inverted: false)
                notice = "Video ready; choose a character mode to play."
            } catch is CancellationError {
                notice = "Video decoding cancelled."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelVideoImport() { videoImport?.cancel() }

    func showVideoAlignment() {
        perform("Sending character alignment ruler…") {
            try await self.prepareDisplay(.video, reopen: true)
            let text = TextVideoStyle.alignmentRuler
            _ = try await self.request("/v1/captions/text", body: ["text": text, "final": true])
            self.videoPreview = text
            self.notice = "Check that the vertical lines at the left and right of the seven rows align; the middle of the second row is blank — that is normal."
        }
    }

    func playVideo(style: TextVideoStyle, fps: Int, inverted: Bool, alignUpdates: Bool, enhanceContrast: Bool = false) {
        guard let video = textVideo, !videoImporting, !videoPlaying, [5, 10].contains(fps) else { return }
        perform("Opening character video…") {
            try await self.prepareDisplay(.video, reopen: true)
            self.videoPlaying = true
            self.videoSeconds = 0
            self.notice = "Playing character video (silent); you can end the session at any time."
            self.videoPlayback = Task {
                defer { self.videoPlaying = false }
                let started = ProcessInfo.processInfo.systemUptime
                var index = 0
                var lastIndex: Int?
                do {
                    while !Task.isCancelled {
                        let elapsed = ProcessInfo.processInfo.systemUptime - started
                        if elapsed >= video.duration { break }
                        while index + 1 < video.frames.count, video.frames[index + 1].seconds <= elapsed { index += 1 }
                        if lastIndex != index {
                            let text = video.frames[index].text(style: style, inverted: inverted, enhanceContrast: enhanceContrast)
                            _ = try await self.request("/v1/captions/text", body: ["text": (alignUpdates && lastIndex != nil ? style.firstCellPadding : "") + text, "final": true])
                            try Task.checkCancellation()
                            self.videoPreview = text
                            lastIndex = index
                            self.videoSeconds = min(elapsed, video.duration)
                        }
                        // Skip missed slots instead of accumulating frames behind the transport.
                        let now = ProcessInfo.processInfo.systemUptime - started
                        let next = (floor(now * Double(fps)) + 1) / Double(fps)
                        try await Task.sleep(nanoseconds: UInt64(max(0, next - now) * 1_000_000_000))
                    }
                    try Task.checkCancellation()
                    self.videoSeconds = video.duration
                    self.notice = "Video finished; the last frame sent remains on the glasses."
                } catch is CancellationError {
                    // The operation that cancelled playback owns the next status message.
                } catch {
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                        self.notice = "Video playback stopped; restart the connection service and try again."
                    }
                }
            }
        }
    }

    private func cancelVideoPlayback() async {
        let previous = videoPlayback
        previous?.cancel()
        await previous?.value
        videoPlayback = nil
        videoPlaying = false
    }

    func showText(_ text: String, translation: String, prompt: Bool, reopen: Bool = false) {
        perform("Sending text…") {
            let mode: DesktopSession = prompt ? .prompts : .captions
            try await self.prepareDisplay(mode, reopen: reopen)
            var body: [String: Any] = ["text": text, "final": true]
            if prompt { body["translation"] = translation }
            _ = try await self.request(prompt ? "/v1/prompts/text" : "/v1/captions/text", body: body)
            if prompt { self.lastPromptContent = body }
            self.notice = "Text sent."
        }
    }

    func notify(title: String, body: String) {
        perform("Sending notification…") {
            try await self.ensureConnected()
            _ = try await self.request("/v1/notifications", body: ["title": title, "body": body])
            self.notice = "Notification sent."
        }
    }

    func startTeleprompter(title: String, text: String, speed: Int) {
        perform("Sending script…") {
            try await self.ensureConnected()
            try await self.stopCurrent()
            _ = try await self.request("/v1/teleprompter", body: ["title": title, "text": text, "speed": speed])
            self.activeSession = .teleprompter
            self.notice = "Script sent."
        }
    }

    func controlTeleprompter(_ action: String) {
        perform("Controlling teleprompter…") {
            _ = try await self.request("/v1/teleprompter/\(action)", body: [:])
            self.notice = action == "pause" ? "Pause command sent." : "Resume command sent."
        }
    }

    func startAudio(recognize: Bool, record: Bool, duration: Int, locale: String) {
        perform(recognize ? "Starting speech recognition…" : "Starting recording…") {
            try await self.ensureConnected()
            if recognize {
                let permission = try await self.request("/v1/asr", method: "GET")
                if permission["speechAuthorization"] as? Int != 3 {
                    self.notice = "Allow speech recognition in the system prompt."
                    let authorized = try await self.request("/v1/asr/authorize", body: [:])
                    guard authorized["speechAuthorization"] as? Int == 3 else { throw DesktopError(message: "Speech recognition is not authorized; allow OpenRayneo in Privacy & Security settings.") }
                }
            }
            try await self.stopCurrent()
            let result = try await self.request(recognize ? "/v1/asr/start" : "/v1/recording/start", body: ["locale": locale, "duration": duration, "record": record])
            self.activeSession = recognize ? .asr : .recording
            self.updateAudio(result)
            self.notice = recognize ? "Recognizing speech with the glasses microphone." : "Recording two-channel audio from the glasses."
        }
    }

    func startLifeLog(duration: Int, record: Bool) {
        perform("Starting the all-day log experiment…") {
            try await self.ensureConnected()
            try await self.stopCurrent()
            let result = try await self.request("/v1/lifelog/observe", body: ["duration": duration, "inspect_audio": true, "record": record])
            self.activeSession = .lifeLog
            self.updateLifeLog(result)
            do {
                let reply = try await self.request("/v1/lifelog/switch", body: ["enabled": true])
                guard reply["acknowledged"] as? Bool == true else {
                    throw DesktopError(message: "No response to the all-day log toggle.")
                }
            } catch {
                try? await self.stopCurrent()
                throw error
            }
            self.notice = "All-day log observation started; speak naturally or click \"Trigger one audio round\"."
        }
    }

    func triggerLifeLogAudio() {
        perform("Requesting one round of all-day log audio…") {
            let result = try await self.request("/v1/lifelog/record", body: [:])
            self.updateLifeLog(result)
            self.notice = "Requested one round of all-day log audio."
        }
    }

    private func updateLifeLog(_ data: [String: Any]) {
        let inspection = data["audioInspection"] as? [String: Any] ?? [:]
        lifeLogSeconds = inspection["decodedSeconds"] as? Double ?? 0
        lifeLogDecodeErrors = inspection["decodeErrors"] as? Int ?? 0
        let recording = inspection["recording"] as? [String: Any]
        recordingPath = recording?["path"] as? String
        recordingFinalized = recording?["finalized"] as? Bool == true
        if let error = inspection["recordingError"] as? String { errorMessage = error }
        let channels = inspection["encodedChannelCounts"] as? [String: Int] ?? [:]
        lifeLogChannels = channels.isEmpty ? "No audio received yet" : channels.keys.sorted().map {
            "\($0) channel: \(channels[$0]!) frames"
        }.joined(separator: "；")
        if let error = data["error"] as? String { errorMessage = error }
    }

    func enterMicrophoneMode() {
        perform("Entering microphone mode…") {
            self.refreshVirtualAudioDevices()
            guard self.builtInMicrophonesReady else {
                throw DesktopError(message: "Install the built-in driver under \"Devices & API\" and refresh devices before entering microphone mode.")
            }
            try await self.prepareDisplay(.prompts, reopen: true)
            if let content = self.lastPromptContent {
                _ = try await self.request("/v1/prompts/text", body: content)
            }
            self.notice = "Microphone mode active; the glasses page stays open while audio devices switch."
        }
    }

    func recoverMicrophoneOutput() {
        perform("Restoring audio output…") {
            let result = try await self.request("/v1/virtual-mic/recover", body: [:])
            self.updateAudio(result)
            self.notice = "Re-checked both audio outputs; the glasses page stays open."
        }
    }

    func refreshVirtualAudioDevices() {
        do {
            virtualAudioDevices = try VirtualMicrophone.availableDevices()
        } catch { errorMessage = error.localizedDescription }
    }

    func openVirtualMicrophoneInstaller() {
        guard let installer = Bundle.main.url(forResource: "OpenRayneoAudio", withExtension: "pkg") else {
            errorMessage = "Built-in driver package not found; rebuild the app with scripts/build-app.sh."
            return
        }
        if NSWorkspace.shared.open(installer) {
            notice = "Finish installing the built-in driver in the system installer. Refresh devices when you return; if the two microphones do not appear, restart your Mac."
        } else { errorMessage = "Unable to open the built-in driver package." }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func stopSession() {
        perform("Ending the current session…") {
            try await self.stopCurrent()
            self.notice = "Stop command sent."
        }
    }

    func revealRecording() {
        if let path = recordingPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    func playRecording() {
        if recordingFinalized, let path = recordingPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    func copyAPIToken() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        notice = "API token of the background service copied."
    }

    func copyAPIAddress() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiAddress, forType: .string)
        notice = "API address copied."
    }

    func copyAPIExample() {
        guard serviceRunning else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiExample.replacingOccurrences(of: "<API_TOKEN>", with: token), forType: .string)
        notice = "Copied the token-authenticated query command; run it directly in Terminal."
    }

    func checkAPI() {
        perform("Checking API…") {
            try await self.verifyAPI()
            self.notice = "API health check, authentication, and glasses connection are all healthy."
        }
    }

    private func verifyAPI() async throws {
        apiVerifiedAt = nil
        let health = try await request("/health", method: "GET", timeout: 5)
        let device = try await request("/v1/device", method: "GET", timeout: 5)
        guard health["ok"] as? Bool == true else { throw DesktopError(message: "Local API health check failed.") }
        let ble = device["ble"] as? [String: Any] ?? [:]
        connected = device["rfcommConnected"] as? Bool == true && ble["ready"] as? Bool == true
        guard connected else { throw DesktopError(message: "The API is reachable, but the glasses are not connected. Reconnect the glasses.") }
        apiVerifiedAt = Date()
    }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !stopping else { return }
        let id = UUID()
        operationID = id
        busy = true
        errorMessage = nil
        notice = message
        operation = Task {
            defer { if operationID == id { busy = false; operation = nil } }
            do { try await action() }
            catch is CancellationError {
                if operationID == id {
                    phase = "Operation cancelled"
                    notice = "Operation stopped. The removed old pairing is not restored."
                }
            }
            catch {
                if operationID == id, !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    if !serviceRunning { phase = "Operation not completed" }
                    notice = "Operation not completed; check the connection and retry."
                }
            }
        }
    }

    private func ensureConnected() async throws {
        try Task.checkCancellation()
        if service?.isRunning != true { try await startService() }
        let status = try await request("/v1/device", method: "GET", timeout: 3)
        connected = status["rfcommConnected"] as? Bool == true && (status["ble"] as? [String: Any])?["ready"] as? Bool == true
        if !connected {
            try await waitForBluetooth(status)
            phase = "Establishing Bluetooth connection"
            notice = "Authenticating the glasses and opening the data channel…"
            let response: [String: Any]
            do {
                response = try await request("/v1/device/connect", body: [:])
            } catch {
                let failure = error
                if !Task.isCancelled, let state = try? await request("/v1/device", method: "GET", timeout: 3),
                   let ble = state["ble"] as? [String: Any] {
                    if ble["ready"] as? Bool == true {
                        throw DesktopError(message: "BLE authentication succeeded, but the data channel was not established. Disconnect first and keep the diagnostics; do not click Connect repeatedly.\n\(failure.localizedDescription)")
                    }
                    if (ble["lastError"] as? String)?.contains("scanning") == true {
                        throw DesktopError(message: "No advertisement from the glasses. Disconnect, then exit and re-enter the glasses pairing mode; retry only once when ready.\n\(failure.localizedDescription)")
                    }
                }
                throw failure
            }
            connected = response["rfcommConnected"] as? Bool == true
            guard connected else { throw DesktopError(message: "The glasses are not connected yet; keep them powered on and near the Mac.") }
        }
        phase = "Connected"
        if apiVerifiedAt == nil { try await verifyAPI() }
        verifiedPairingAddress = selectedAddress
        notice = "Glasses connected; the local API is ready."
    }

    private func waitForBluetooth(_ initial: [String: Any]) async throws {
        var status = initial
        let deadline = Date().addingTimeInterval(90)
        while true {
            try Task.checkCancellation()
            let ble = status["ble"] as? [String: Any] ?? [:]
            let state = ble["bluetoothState"] as? Int ?? 0
            let authorization = ble["bluetoothAuthorization"] as? Int
            if state == 3 || authorization == 1 || authorization == 2 {
                throw DesktopError(message: "Bluetooth access is not authorized; allow OpenRayneo in System Settings → Privacy & Security → Bluetooth.")
            }
            if state == 5 { return }
            if state == 4 { throw DesktopError(message: "Mac Bluetooth is off; turn it on and retry.") }
            if state == 2 { throw DesktopError(message: "This Mac does not provide usable Bluetooth support.") }
            guard Date() < deadline else { throw DesktopError(message: "System Bluetooth is not ready. Resolve the permission prompt and reconnect.") }
            phase = "Waiting for system Bluetooth"
            notice = "Waiting for system Bluetooth; if a permission prompt appears, allow OpenRayneo."
            try await Task.sleep(nanoseconds: 500_000_000)
            status = try await request("/v1/device", method: "GET", timeout: 3)
        }
    }

    private func prepareDisplay(_ mode: DesktopSession, reopen: Bool) async throws {
        try await ensureConnected()
        if activeSession == mode, !reopen { return }
        try await stopCurrent()
        let prefix = mode == .prompts ? "/v1/prompts" : "/v1/captions"
        let font = mode == .video ? 1 : 2
        let lines = mode == .video ? 7 : 5
        var body: [String: Any] = ["font_size": font, "content_width": 100, "max_lines": lines]
        if mode == .prompts {
            refreshVirtualAudioDevices()
            body["microphone_enabled"] = builtInMicrophonesReady
            body["duration"] = microphoneDuration
        }
        let response = try await request(prefix + "/start", body: body)
        guard response["accepted"] as? Bool == true else {
            _ = try? await request(prefix + "/stop", body: [:], timeout: 5)
            throw DesktopError(message: "No display-start confirmation from the glasses; try again.")
        }
        activeSession = mode
        if mode == .prompts { updateAudio(response) }
        if mode == .navigation || mode == .video {
            let config = (response["reply"] as? [String: Any])?["effective_config"] as? [String: Any]
            guard config?["font_size"] as? Int == font, config?["max_lines"] as? Int == lines, config?["content_width"] as? Int == 100 else {
                try await stopCurrent()
                throw DesktopError(message: "The glasses returned a different layout configuration; the character grid was not sent.")
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func startDefaultPromptIfIdle() async throws {
        guard activeSession == nil else { return }
        try await prepareDisplay(.prompts, reopen: false)
        notice = microphoneForwarding
            ? "Glasses connected with both microphones on; question and answer can be sent together."
            : "Glasses connected; question and answer can be sent. After installing the built-in driver, reopen Live Prompts to relay both microphones."
    }

    private func stopCurrent() async throws {
        await cancelVideoPlayback()
        guard let current = activeSession else { return }
        let result = try await request(current.stopPath, body: [:])
        if current == .lifeLog { updateLifeLog(result) }
        else if current.isAudio { updateAudio(result) }
        activeSession = nil
    }

    private func request(_ path: String, method: String = "POST", body: [String: Any]? = nil, timeout: TimeInterval = 75) async throws -> [String: Any] {
        guard !apiAddress.isEmpty else { throw DesktopError(message: "The background service has not started; connect the glasses first.") }
        var request = URLRequest(url: URL(string: apiAddress + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await network.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DesktopError(message: json["error"] as? String ?? "The background service did not complete the request.")
        }
        return json
    }

    private func startService() async throws {
        guard service?.isRunning != true else { throw DesktopError(message: "The previous connection service has not exited; the new process was not started.") }
        guard !selectedAddress.isEmpty else { throw DesktopError(message: "Click \"Add & Pair Glasses\" first, or refresh the paired devices list.") }
        activeSession = nil
        microphoneForwarding = false
        apiVerifiedAt = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        monitor?.cancel()
        let port = try Self.availablePort()
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--headless"]
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var environment = ProcessInfo.processInfo.environment
        environment["OPENRAYNEO_API_TOKEN"] = token
        environment["OPENRAYNEO_PORT"] = String(port)
        environment["RAYNEO_ADDRESS"] = selectedAddress
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardError = pipe
        stderrText = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let child, self.service === child else { return }
                self.stderrText = String((self.stderrText + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.service === process, !self.stopping else { return }
                self.connected = false
                self.serviceRunning = false
                self.serviceProcessID = nil
                self.activeSession = nil
                self.microphoneForwarding = false
                self.videoPlayback?.cancel()
                self.apiVerifiedAt = nil
                self.phase = "Background service exited"
                self.errorMessage = self.stderrText.isEmpty ? "Background service exited; reconnect." : self.stderrText
            }
        }
        try child.run()
        service = child
        serviceProcessID = child.processIdentifier
        stderrPipe = pipe
        apiAddress = "http://127.0.0.1:\(port)"
        serviceRunning = true
        phase = "Starting background service"
        UserDefaults.standard.set(selectedAddress, forKey: "selectedGlasses")
        do {
            var ready = false
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard child.isRunning else { throw DesktopError(message: stderrText.isEmpty ? "Background service failed to start." : stderrText) }
                // An authenticated read proves readiness of our child, not another service on the port.
                if (try? await request("/v1/device", method: "GET", timeout: 0.5)) != nil { ready = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ready else { throw DesktopError(message: "Background service start timed out; retry.") }
            startMonitoring()
        } catch {
            let stopped = await BridgeProcessLifecycle.stop(child)
            serviceRunning = !stopped
            if stopped { serviceProcessID = nil }
            throw error
        }
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task {
            while !Task.isCancelled, service?.isRunning == true {
                if let data = try? await request("/v1/device", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    connected = data["rfcommConnected"] as? Bool == true && (data["ble"] as? [String: Any])?["ready"] as? Bool == true
                    if !connected { apiVerifiedAt = nil }
                    let ble = data["ble"] as? [String: Any] ?? [:]
                    let rawPhase = ble["phase"] as? String ?? "idle"
                    let names = ["idle": "Waiting for connection", "waitingForBluetooth": "Waiting for system Bluetooth", "scanning": "Looking for glasses", "connecting": "Connecting to glasses", "discoveringServices": "Discovering Bluetooth services", "discoveringCharacteristics": "Preparing Bluetooth channel", "readingIdentity": "Verifying glasses identity", "subscribing": "Preparing notification channel", "exchangingDeviceInfo": "Exchanging device info", "authenticating": "Authenticating glasses", "authenticated": "Opening data channel", "failed": "Connection failed"]
                    phase = connected ? "Connected" : ble["bluetoothState"] as? Int == 0 ? "Waiting for system Bluetooth" : names[rawPhase] ?? "Connection stage: \(rawPhase)"
                    if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { diagnostics = String(decoding: bytes, as: UTF8.self) }
                } else if !Task.isCancelled { connected = false; apiVerifiedAt = nil; phase = "Background service temporarily unresponsive" }
                if activeSession == .lifeLog,
                   let state = try? await request("/v1/lifelog", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    updateLifeLog(state)
                    if state["observing"] as? Bool == false {
                        activeSession = nil
                        notice = "All-day log observation ended."
                    }
                }
                if activeSession == .asr || activeSession == .recording || (activeSession == .prompts && microphoneForwarding),
                   let audio = try? await request("/v1/asr", method: "GET", timeout: 2) {
                    guard !Task.isCancelled else { return }
                    updateAudio(audio)
                    if audio["running"] as? Bool == false {
                        activeSession = nil
                        notice = "Audio session ended."
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateAudio(_ data: [String: Any]) {
        transcript = data["transcript"] as? String ?? ""
        audioSeconds = data["decodedSeconds"] as? Double ?? 0
        let microphones = data["virtualMicrophones"] as? [[String: Any]] ?? []
        microphoneAudioState = data["audioState"] as? String ?? "stopped"
        microphoneForwarding = data["running"] as? Bool == true && data["engine"] as? String == "virtual-microphone"
        microphoneRecovering = microphoneForwarding && microphones.contains { $0["recovering"] as? Bool == true }
        virtualMicrophoneName = microphones.compactMap { $0["deviceName"] as? String }.joined(separator: "、")
        if let recording = data["recording"] as? [String: Any] {
            recordingPath = recording["path"] as? String
            recordingFinalized = recording["finalized"] as? Bool == true
        } else {
            recordingPath = nil
            recordingFinalized = false
        }
        if let error = data["error"] as? String { errorMessage = error }
    }

    @discardableResult
    func shutdown() async -> Bool {
        guard !stopping else { return false }
        stopping = true
        defer { stopping = false }
        phase = restartingService ? "Restarting connection service" : "Stopping connection service"
        pairing.cancel()
        await cancelVideoPlayback()
        operationID = nil
        let previousOperation = operation
        let previousMonitor = monitor
        previousOperation?.cancel()
        previousMonitor?.cancel()
        await previousOperation?.value
        await previousMonitor?.value
        operation = nil
        monitor = nil
        if let child = service, child.isRunning {
            if let current = activeSession {
                if let result = try? await request(current.stopPath, body: [:], timeout: 5) {
                    if current == .lifeLog { updateLifeLog(result) }
                    else if current.isAudio { updateAudio(result) }
                }
            }
            // Also catches a start request completed by the server after client cancellation.
            if let result = try? await request("/v1/asr/stop", body: [:], timeout: 3) { updateAudio(result) }
            guard await BridgeProcessLifecycle.stop(child) else {
                connected = false
                apiVerifiedAt = nil
                busy = false
                phase = "Connection service failed to exit"
                errorMessage = "The previous connection process has not exited; the restart flow was stopped. Keep the diagnostics and retry."
                return false
            }
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        service = nil
        serviceProcessID = nil
        connected = false
        apiVerifiedAt = nil
        serviceRunning = false
        activeSession = nil
        microphoneForwarding = false
        phase = "Disconnected"
        busy = false
        apiAddress = ""
        diagnostics = ""
        token = ""
        return true
    }

    private static func availablePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopError(message: "Unable to create the local service port.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = (UInt16(ProcessInfo.processInfo.environment["OPENRAYNEO_PORT"] ?? "8765") ?? 8765).bigEndian
        let bind = { withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        if bind() != 0 { address.sin_port = 0; guard bind() == 0 else { throw DesktopError(message: "Unable to allocate a local service port.") } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard result == 0 else { throw DesktopError(message: "Unable to read the local service port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
