import Foundation
import StikJIT

private struct JITRequest: Decodable {
    let operation: String
    let pairingData: Data?
    let bundleIdentifier: String?
    let groupIdentifier: String?
    let logToken: String?
}

private struct JITApplication: Encodable {
    let name: String
    let bundleIdentifier: String
    let pid: Int32?
}

private struct JITResponse: Encodable {
    let success: Bool
    let message: String
    let txmPresent: Bool?
    let applications: [JITApplication]?
    let logs: [String]
}

private final class JITProgress {
    private(set) var lines: [String] = []
    private let logURL: URL?

    init(groupIdentifier: String?, logToken: String?) {
        guard let groupIdentifier, let logToken,
              UUID(uuidString: logToken) != nil,
              let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            logURL = nil
            return
        }
        let directory = root.appendingPathComponent("Library/Caches/WQJIT", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("\(logToken).jsonl")
    }

    func report(_ text: String, fraction: Double? = nil) {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        lines.append(clean)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        guard let logURL else { return }
        var event: [String: Any] = ["text": clean]
        if let fraction { event["fraction"] = max(0, min(1, fraction)) }
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

private enum JITWork {
    static let queue = DispatchQueue(label: "cz.kolbi.wqfiles.jit-helper")

    static func run(_ request: JITRequest) -> JITResponse {
        let progress = JITProgress(groupIdentifier: request.groupIdentifier,
                                   logToken: request.logToken)
        func result(_ success: Bool, _ message: String,
                    _ apps: [JITApplication]? = nil) -> JITResponse {
            JITResponse(success: success, message: message,
                        txmPresent: StikJIT.isTXMPresent,
                        applications: apps, logs: progress.lines)
        }
        let manager = FileManager.default
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let cache = library.appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: cache)
        do {
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            if request.operation == "reset" {
                progress.report("Resetting Developer Disk Image cache…")
                try StikJIT.resetCachedDDI(at: paths)
                progress.report("Developer Disk Image cache reset.", fraction: 1)
                return result(true, "Developer Disk Image cache reset.")
            }
            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                return result(false, "Import a pairing file first.")
            }
            let pairingURL = manager.temporaryDirectory
                .appendingPathComponent("pairing-\(UUID().uuidString).mobiledevicepairing")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            if request.operation == "list" {
                progress.report("Connecting to the device app service…", fraction: 0.1)
                let apps = try StikJIT.installedApplications(pairingFile: pairingURL)
                    .map { JITApplication(name: $0.name,
                                          bundleIdentifier: $0.bundleIdentifier,
                                          pid: $0.pid) }
                progress.report("Found \(apps.count) installed apps.", fraction: 1)
                return result(true, "Connected", apps)
            }

            if request.operation == "prepare" || request.operation == "enable" {
                progress.report("Checking device and Developer Disk Image…", fraction: 0.05)
                if request.operation == "prepare" {
                    let readiness = StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths) {
                        stage in report(stage, to: progress)
                    }
                    switch readiness {
                    case .ready:
                        return result(true, "Device ready")
                    case .unreachable(let reason), .preparationFailed(let reason):
                        progress.report(reason)
                        return result(false, reason)
                    @unknown default:
                        return result(false, "Unknown preparation result.")
                    }
                }

                guard let bundleID = request.bundleIdentifier, !bundleID.isEmpty else {
                    return result(false, "Select an app to enable JIT.")
                }
                progress.report("Finding the selected app's current process…", fraction: 0.1)
                guard let app = try StikJIT.installedApplications(pairingFile: pairingURL)
                    .first(where: { $0.bundleIdentifier == bundleID }), let pid = app.pid else {
                    return result(false, "The selected app is not running. Open it, return to WQ Files, and refresh the list.")
                }
                progress.report("Attaching debugger to \(app.name) (PID \(pid))…", fraction: 0.2)
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingURL,
                                      ddiPaths: paths, script: .universal,
                                      forceScript: false,
                                      preparationProgress: { stage in report(stage, to: progress) },
                                      progress: { progress.report($0) })
                progress.report("Debugger operation completed for \(app.name).", fraction: 1)
                return result(true, "Debugger completed. Verify JIT in the target app.")
            }
            return result(false, "Unknown JIT operation.")
        } catch {
            progress.report("Failed: \(error.localizedDescription)")
            return result(false, error.localizedDescription)
        }
    }

    private static func report(_ stage: StikJIT.PreparationStage, to progress: JITProgress) {
        switch stage {
        case .checkingReachability: progress.report("Checking LocalDevVPN connection…", fraction: 0.25)
        case .checkingDDI: progress.report("Checking Developer Disk Image…", fraction: 0.35)
        case .downloadingDDI(let fraction, let status):
            progress.report("Downloading DDI: \(status)", fraction: 0.4 + 0.35 * fraction)
        case .mountingDDI(let fraction):
            progress.report("Mounting DDI…", fraction: 0.75 + 0.15 * fraction)
        case .verifyingDDI: progress.report("Verifying DDI mount…", fraction: 0.92)
        case .ready: progress.report("Developer Disk Image ready.", fraction: 0.95)
        @unknown default: progress.report("Preparing device…")
        }
    }
}

@objc(WQJITHelperHandler)
final class WQJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let data = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?["wq-jit-request"] as? Data
        JITWork.queue.async {
            let response: JITResponse
            if let data, let request = try? JSONDecoder().decode(JITRequest.self, from: data) {
                response = JITWork.run(request)
            } else {
                response = JITResponse(success: false, message: "Invalid helper request.",
                                       txmPresent: nil, applications: nil,
                                       logs: ["Invalid helper request."])
            }
            let item = NSExtensionItem()
            item.userInfo = ["wq-jit-response": (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
