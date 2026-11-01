// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreBluetooth
import IOBluetooth
import Foundation

enum RayneoAdvertisement {
    static func classicAddress(_ advertisement: [String: Any]) -> String? {
        // Official APK S3.C0912a: company 0x5716, model 0x06, six address bytes.
        // CoreBluetooth includes the little-endian company ID in manufacturer data.
        guard let data = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 9, Array(data.prefix(3)) == [0x16, 0x57, 0x06] else { return nil }
        return data.dropFirst(3).prefix(6).map { String(format: "%02X", $0) }.joined(separator: "-")
    }
}

private struct PairingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension PairedGlasses {
    static func systemInventory() async throws -> [PairedGlasses] {
        // IOBluetooth pairedDevices() can block indefinitely in GUI processes.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "10"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let controllers = report["SPBluetoothDataType"] as? [[String: Any]] else {
                throw PairingError(message: "Failed to read system Bluetooth devices; open Bluetooth settings and retry.")
            }
            var result: [PairedGlasses] = []
            for controller in controllers {
                for key in ["device_connected", "device_not_connected"] {
                    for entry in controller[key] as? [[String: Any]] ?? [] {
                        for (name, value) in entry where name.localizedCaseInsensitiveContains("RayNeo iO") {
                            if let info = value as? [String: Any], let address = info["device_address"] as? String {
                                let normalized = address.replacingOccurrences(of: ":", with: "-")
                                if !result.contains(where: { $0.id == normalized }) { result.append(PairedGlasses(id: normalized, name: name)) }
                            }
                        }
                    }
                }
            }
            return result
        }.value
    }
}

/// Discovery stays in the UI; native pairing and status checks run in separate processes.
@MainActor
final class BluetoothPairing: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var candidates: [PairedGlasses] = []
    private var helper: Process?
    private var cancelled = false
    private var scanning = false
    private var alert: NSAlert?

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func pair(progress: (String, String) -> Void) async throws -> PairedGlasses? {
        cancelled = false
        candidates = []
        defer { stopDiscovery(); dismissAlert() }
        let target: PairedGlasses
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        progress("Waiting for Bluetooth", "If macOS asks for Bluetooth permission, allow OpenRayneo.")
        let deadline = Date().addingTimeInterval(90)
        while central?.state != .poweredOn {
            try checkState()
            guard Date() < deadline else { throw PairingError(message: "Timed out waiting for system Bluetooth; resolve the permission prompt and retry.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        progress("Looking for glasses", "Keep the glasses in pairing mode and your phone Bluetooth off.")
        scanning = true
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let scanStart = Date()
        while Date().timeIntervalSince(scanStart) < (candidates.isEmpty ? 20 : 8) {
            try checkState()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stopDiscovery()
        guard !candidates.isEmpty else { throw PairingError(message: "No advertisement from the glasses. Exit, re-enter the glasses pairing mode, and click Add once more; do not retry repeatedly.") }
        if candidates.count == 1 { target = candidates[0] }
        else {
            let prompt = NSAlert()
            prompt.messageText = "Choose glasses to pair"
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
            picker.addItems(withTitles: candidates.map { "\($0.name) · \($0.id.suffix(5))" })
            prompt.accessoryView = picker
            prompt.addButton(withTitle: "Continue")
            prompt.addButton(withTitle: "Cancel")
            guard await show(prompt) == .alertFirstButtonReturn else { return nil }
            target = candidates[picker.indexOfSelectedItem]
        }
        try checkState()
        progress("Removing old Mac pairing", "Removing the local pairing record for \(target.name). Leave the glasses as they are; do not touch Bluetooth settings meanwhile.")
        _ = try await runHelper(["--unpair", target.id], timeout: 15)
        progress("Confirming pairing removed", "Independently confirming the glasses are unpaired and disconnected on this Mac.")
        let clean = try await pairingState(target.id)
        guard !clean.paired, !clean.connected else {
            throw PairingError(message: "The Mac still has a pairing or connection; stopped without starting a new pairing. Remove the glasses in Bluetooth settings and try again.")
        }
        progress("Pairing glasses", "Creating a new pairing with \(target.name). Do not remove the device in System Settings or re-enter the glasses pairing mode meanwhile.")
        _ = try await runHelper(["--pair", target.id], timeout: 35)
        progress("Confirming system pairing", "The pairing assistant exited; independently confirming the pairing record.")
        guard try await pairingState(target.id).paired else {
            throw PairingError(message: "The pairing assistant finished, but the Mac saved no pairing. Stop touching Bluetooth settings, check the glasses, and try again.")
        }
        try checkState()
        return target
    }

    private func pairingState(_ address: String) async throws -> (paired: Bool, connected: Bool) {
        let output = try await runHelper(["--pairing-status", address], timeout: 10)
        guard let state = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let paired = state["isPaired"] as? Bool,
              let connected = state["isConnected"] as? Bool else {
            throw PairingError(message: "Unable to read the system pairing state.")
        }
        return (paired, connected)
    }

    private func runHelper(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["OPENRAYNEO_PAIRING_UI"] = "1"
        child.environment = environment
        let output = Pipe()
        let input = Pipe()
        child.standardOutput = output
        child.standardError = output
        child.standardInput = input
        try child.run()
        helper = child
        let reader = Task.detached { [self] () throws -> String in
            var pending = Data()
            var text = ""
            while let data = try output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    text += line + "\n"
                    await handleLine(line, child: child, input: input.fileHandleForWriting)
                }
            }
            return text + String(decoding: pending, as: UTF8.self)
        }
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while child.isRunning {
                try checkState()
                guard Date() < deadline else { throw PairingError(message: "The pairing assistant timed out and stopped; check the glasses and try again.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            dismissAlert()
            let text = try await reader.value
            helper = nil
            try checkState()
            guard child.terminationStatus == 0 else {
                throw PairingError(message: "Pairing did not complete (exit \(child.terminationStatus)).\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text
        } catch {
            dismissAlert()
            if child.isRunning { child.terminate() }
            await Task.detached {
                for _ in 0..<20 where child.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }.value
            _ = try? await reader.value
            helper = nil
            throw error
        }
    }

    private func handleLine(_ line: String, child: Process, input: FileHandle) async {
        guard !cancelled, helper === child, child.isRunning,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let event = object["event"] else { return }
        let prompt = NSAlert()
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        switch event {
        case "confirmation":
            prompt.messageText = "Verify the glasses pairing number"
            prompt.informativeText = "Click Pair only if the number on the glasses matches the one below."
            prompt.accessoryView = NSTextField(labelWithString: object["value"] ?? "")
            prompt.addButton(withTitle: "Pair")
        case "pin":
            prompt.messageText = "Enter the glasses Bluetooth PIN"
            prompt.informativeText = "Enter the PIN shown on the glasses."
            prompt.accessoryView = field
            prompt.addButton(withTitle: "Submit")
        case "passkey":
            prompt.messageText = "Enter the pairing code on the glasses"
            prompt.accessoryView = NSTextField(labelWithString: object["value"] ?? "")
            prompt.addButton(withTitle: "Done")
        default: return
        }
        prompt.addButton(withTitle: "Cancel")
        let accepted = await show(prompt) == .alertFirstButtonReturn
        guard !cancelled, helper === child, child.isRunning else { return }
        if !accepted { cancel(); return }
        let reply = event == "pin" ? field.stringValue : "yes"
        if event != "passkey" { try? input.write(contentsOf: Data((reply + "\n").utf8)) }
    }

    private func checkState() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        switch central?.state {
        case .unauthorized: throw PairingError(message: "Allow OpenRayneo to access Bluetooth in Privacy & Security settings.")
        case .poweredOff: throw PairingError(message: "Mac Bluetooth is off; turn it on and retry.")
        case .unsupported: throw PairingError(message: "This Mac does not support the required Bluetooth connection.")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "RayNeo iO"
        guard let address = RayneoAdvertisement.classicAddress(advertisementData) else { return }
        if !candidates.contains(where: { $0.id == address }) { candidates.append(PairedGlasses(id: address, name: name)) }
    }

    private func show(_ prompt: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return .abort }
        alert = prompt
        defer { alert = nil }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            prompt.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func dismissAlert() {
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
    }

    func cancel() {
        cancelled = true
        stopDiscovery()
        dismissAlert()
        if helper?.isRunning == true { helper?.terminate() }
    }

    private func stopDiscovery() {
        scanning = false
        central?.stopScan()
        central?.delegate = nil
        central = nil
    }
}
