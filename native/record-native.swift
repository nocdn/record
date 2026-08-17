import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct NativeOptions {
    var outputPath: String = ""
    var display: Int = 1
    var fps: Double = 30
    var format: String = "mp4"
    var microphone = true
    var microphoneName: String?
    var systemAudio = true
    var cursor = true
    var onlyMic = false
    var listMics = false
    var permissions = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--permissions":
                permissions = true
            case "--list-mics":
                listMics = true
            case "--output":
                index += 1
                outputPath = try value(arguments, index, argument)
            case "--display":
                index += 1
                display = try positiveInt(value(arguments, index, argument), argument)
            case "--fps":
                index += 1
                fps = try positiveDouble(value(arguments, index, argument), argument)
            case "--format":
                index += 1
                format = try value(arguments, index, argument)
            case "--no-mic":
                microphone = false
            case "--mic":
                index += 1
                microphoneName = try value(arguments, index, argument)
                microphone = true
            case "--no-system-audio":
                systemAudio = false
            case "--no-cursor":
                cursor = false
            case "--only-mic", "--mic-only":
                onlyMic = true
                microphone = true
                systemAudio = false
            default:
                throw RecorderError.message("Unknown native option \(argument).")
            }
            index += 1
        }
    }

    private func value(_ arguments: [String], _ index: Int, _ flag: String) throws -> String {
        guard arguments.indices.contains(index), !arguments[index].isEmpty else {
            throw RecorderError.message("Option \(flag) requires a value.")
        }
        return arguments[index]
    }

    private func positiveInt(_ value: String, _ flag: String) throws -> Int {
        guard let number = Int(value), number > 0 else {
            throw RecorderError.message("Option \(flag) must be a positive integer.")
        }
        return number
    }

    private func positiveDouble(_ value: String, _ flag: String) throws -> Double {
        guard let number = Double(value), number > 0, number <= 120 else {
            throw RecorderError.message("Option \(flag) must be greater than 0 and no more than 120.")
        }
        return number
    }
}

enum RecorderError: Error, LocalizedError {
    case message(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .permission(let message):
            return message
        }
    }
}

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, AVCaptureFileOutputRecordingDelegate {
    private let options: NativeOptions
    private let outputLock = NSLock()
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var captureSession: AVCaptureSession?
    private var audioFileOutput: AVCaptureAudioFileOutput?
    private var progressTimer: DispatchSourceTimer?
    private var stopRequested = false
    private var completed = false
    private var completionStatus: Int32 = 0
    private var selectedMicrophoneName: String?

    init(options: NativeOptions) {
        self.options = options
        super.init()
    }

    func run() async -> Int32 {
        if options.permissions {
            return reportPermissions()
        }

        if options.listMics {
            return listMicrophones()
        }

        do {
            try await startRecording()
            installInputHandler()
            return await waitForCompletion()
        } catch {
            emitError(error.localizedDescription)
            if case RecorderError.permission = error {
                return 2
            }
            return 1
        }
    }

    private func startRecording() async throws {
        guard #available(macOS 15.0, *) else {
            throw RecorderError.message("@nocdn/record requires macOS 15 or later.")
        }

        if options.onlyMic {
            try await startMicrophoneRecording()
            return
        }

        try await startScreenRecording()
    }

    private func startMicrophoneRecording() async throws {
        try await ensureMicrophonePermission()

        let device = try resolveMicrophoneDevice()
        selectedMicrophoneName = device.localizedName
        let session = AVCaptureSession()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderError.message("Could not use the selected microphone.")
        }
        session.addInput(input)

        let fileOutput = AVCaptureAudioFileOutput()
        guard session.canAddOutput(fileOutput) else {
            throw RecorderError.message("Could not create an audio file output.")
        }
        session.addOutput(fileOutput)

        captureSession = session
        audioFileOutput = fileOutput

        session.startRunning()
        guard session.isRunning else {
            throw RecorderError.message("The microphone capture session failed to start.")
        }

        let outputURL = URL(fileURLWithPath: options.outputPath)
        fileOutput.startRecording(
            to: outputURL,
            outputFileType: audioFileType(for: outputURL),
            recordingDelegate: self
        )
    }

    private func startScreenRecording() async throws {
        try await ensureMicrophonePermission()
        try ensureScreenPermission()

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard shareableContent.displays.indices.contains(options.display - 1) else {
            throw RecorderError.message(
                "Display \(options.display) was not found. Available displays: 1–\(shareableContent.displays.count)."
            )
        }

        let display = shareableContent.displays[options.display - 1]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelSize = nativePixelSize(for: display, filter: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.minimumFrameInterval = CMTime(
            seconds: 1 / options.fps,
            preferredTimescale: 600
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = options.cursor
        configuration.queueDepth = 8
        configuration.capturesAudio = options.systemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.microphone

        if options.microphone {
            let device = try resolveMicrophoneDevice()
            configuration.microphoneCaptureDeviceID = device.uniqueID
            selectedMicrophoneName = device.localizedName
        }

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = URL(fileURLWithPath: options.outputPath)
        recordingConfiguration.videoCodecType = AVVideoCodecType.h264
        recordingConfiguration.outputFileType = options.format == "mov"
            ? .mov
            : .mp4

        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let contentStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        try contentStream.addRecordingOutput(output)

        stream = contentStream
        recordingOutput = output

        try await contentStream.startCapture()
    }

    private func ensureMicrophonePermission() async throws {
        guard options.microphone else {
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.permission(
                    "Microphone permission was denied. Grant it in System Settings → Privacy & Security → Microphone."
                )
            }
        case .denied, .restricted:
            throw RecorderError.permission(
                "Microphone permission is not granted. Grant it in System Settings → Privacy & Security → Microphone."
            )
        @unknown default:
            throw RecorderError.message("The microphone permission status is unknown.")
        }
    }

    private func ensureScreenPermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecorderError.permission(
                "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then run the command again."
            )
        }
    }

    private func installInputHandler() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                self?.requestStop()
                return
            }

            guard let input = String(data: data, encoding: .utf8) else {
                return
            }

            for line in input.split(separator: "\n") {
                if line.contains("\"command\":\"stop\"") {
                    self?.requestStop()
                }
            }
        }
    }

    private func waitForCompletion() async -> Int32 {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if completed {
                stateLock.unlock()
                continuation.resume(returning: completionStatus)
            } else {
                completionContinuation = continuation
                stateLock.unlock()
            }
        }
    }

    private var completionContinuation: CheckedContinuation<Int32, Never>?

    private func requestStop() {
        stateLock.lock()
        if stopRequested {
            stateLock.unlock()
            return
        }
        stopRequested = true
        stateLock.unlock()

        emit(["event": "finalizing"])
        progressTimer?.cancel()
        FileHandle.standardInput.readabilityHandler = nil

        if let audioFileOutput {
            if audioFileOutput.isRecording {
                audioFileOutput.stopRecording()
            } else {
                captureSession?.stopRunning()
                complete(status: 1)
            }
            return
        }

        guard let stream else {
            complete(status: 1)
            return
        }

        stream.stopCapture { [weak self] error in
            if let error {
                self?.emitError(error.localizedDescription)
                self?.complete(status: 1)
            }
        }
    }

    private func complete(status: Int32) {
        stateLock.lock()
        if completed {
            stateLock.unlock()
            return
        }
        completed = true
        completionStatus = status
        let continuation = completionContinuation
        completionContinuation = nil
        stateLock.unlock()

        FileHandle.standardInput.readabilityHandler = nil
        progressTimer?.cancel()
        continuation?.resume(returning: status)
    }

    private func reportPermissions() -> Int32 {
        let screenStatus = CGPreflightScreenCaptureAccess() ? "granted" : "not granted"
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? "granted"
            : "not granted"
        print("Screen & System Audio: \(screenStatus)")
        print("Microphone: \(microphoneStatus)")
        return screenStatus == "granted" && microphoneStatus == "granted" ? 0 : 1
    }

    private func emitStarted() {
        var payload: [String: Any] = [
            "event": "started",
            "path": options.outputPath,
        ]
        if let selectedMicrophoneName {
            payload["microphone"] = selectedMicrophoneName
        }
        emit(payload)
        startProgressTimer()
    }

    private func startProgressTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            let duration: Double
            let bytes: Int64
            if let recordingOutput = self.recordingOutput {
                duration = CMTimeGetSeconds(recordingOutput.recordedDuration)
                bytes = Int64(recordingOutput.recordedFileSize)
            } else if let audioFileOutput = self.audioFileOutput {
                duration = CMTimeGetSeconds(audioFileOutput.recordedDuration)
                bytes = Int64(audioFileOutput.recordedFileSize)
            } else {
                return
            }

            self.emit([
                "event": "progress",
                "duration": duration,
                "bytes": bytes,
            ])
        }
        progressTimer = timer
        timer.resume()
    }

    private func listMicrophones() -> Int32 {
        let devices = discoverMicrophones()
        if devices.isEmpty {
            print("No microphones were found.")
            return 1
        }

        let builtInID = try? builtInMicrophone().uniqueID
        let systemDefaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let sortedDevices = devices.sorted { left, right in
            let leftBuiltIn = left.uniqueID == builtInID
            let rightBuiltIn = right.uniqueID == builtInID
            if leftBuiltIn != rightBuiltIn {
                return leftBuiltIn
            }
            return left.localizedName.localizedStandardCompare(right.localizedName) == .orderedAscending
        }

        for device in sortedDevices {
            var tags: [String] = []
            if device.uniqueID == builtInID {
                tags.append("built-in")
                tags.append("default")
            } else if isBuiltInMicrophone(device) {
                tags.append("built-in")
            }
            if device.uniqueID == systemDefaultID, device.uniqueID != builtInID {
                tags.append("system default")
            }
            if tags.isEmpty {
                print(device.localizedName)
            } else {
                print("\(device.localizedName)  (\(tags.joined(separator: ", ")))")
            }
        }

        return 0
    }

    private func resolveMicrophoneDevice() throws -> AVCaptureDevice {
        if let microphoneName = options.microphoneName {
            return try findMicrophone(named: microphoneName)
        }
        return try builtInMicrophone()
    }

    private func findMicrophone(named query: String) throws -> AVCaptureDevice {
        let devices = discoverMicrophones()
        if let byID = devices.first(where: { $0.uniqueID == query }) {
            return byID
        }

        if let exact = devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact
        }

        let partial = devices.filter {
            $0.localizedName.localizedCaseInsensitiveContains(query)
        }
        if partial.count == 1 {
            return partial[0]
        }
        if partial.count > 1 {
            let names = partial.map(\.localizedName).joined(separator: ", ")
            throw RecorderError.message(
                "Microphone \"\(query)\" matches more than one device: \(names). Use a more specific name from the mics command."
            )
        }

        throw RecorderError.message(
            "Microphone \"\(query)\" was not found. Run the mics command to list devices."
        )
    }

    private func builtInMicrophone() throws -> AVCaptureDevice {
        let devices = discoverMicrophones()
        let builtIn = devices.filter(isBuiltInMicrophone)

        if let macbook = builtIn.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("MacBook")
        }) {
            return macbook
        }

        if let byID = devices.first(where: {
            $0.uniqueID.caseInsensitiveCompare("BuiltInMicrophoneDevice") == .orderedSame
                || $0.uniqueID.localizedCaseInsensitiveContains("BuiltInMicrophone")
        }) {
            return byID
        }

        if let only = builtIn.count == 1 ? builtIn[0] : nil {
            return only
        }

        if let first = builtIn.first {
            return first
        }

        throw RecorderError.message(
            "No built-in Mac microphone was found. Use --mic to choose a device, or run the mics command to list them."
        )
    }

    private func isBuiltInMicrophone(_ device: AVCaptureDevice) -> Bool {
        device.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
            || device.uniqueID.localizedCaseInsensitiveContains("BuiltInMicrophone")
    }

    private func discoverMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private func nativePixelSize(for display: SCDisplay, filter: SCContentFilter) -> (width: Int, height: Int) {
        var width: Int
        var height: Int
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            width = mode.pixelWidth
            height = mode.pixelHeight
        } else {
            let scale = CGFloat(filter.pointPixelScale)
            width = Int((filter.contentRect.width * scale).rounded())
            height = Int((filter.contentRect.height * scale).rounded())
        }

        if width % 2 != 0 {
            width -= 1
        }
        if height % 2 != 0 {
            height -= 1
        }

        return (max(width, 2), max(height, 2))
    }

    private func audioFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "wav":
            return .wav
        case "caf":
            return .caf
        case "aif", "aiff":
            return .aiff
        case "mp4":
            return .mp4
        default:
            return .m4a
        }
    }

    private func emitError(_ message: String) {
        emit(["event": "error", "message": message])
    }

    private func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        outputLock.lock()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        outputLock.unlock()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        emitStarted()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        emitError(error.localizedDescription)
        complete(status: 1)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        emit(["event": "saved", "path": options.outputPath])
        complete(status: 0)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !stopRequested {
            emitError(error.localizedDescription)
            complete(status: 1)
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        emitStarted()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        captureSession?.stopRunning()
        if let error {
            emitError(error.localizedDescription)
            complete(status: 1)
            return
        }

        emit(["event": "saved", "path": options.outputPath])
        complete(status: 0)
    }
}

@main
struct RecordNativeMain {
    static func main() async {
        do {
            let options = try NativeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let recorder = Recorder(options: options)
            exit(await recorder.run())
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            let data = try? JSONSerialization.data(withJSONObject: [
                "event": "error",
                "message": message,
            ])
            if let data {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            exit(1)
        }
    }
}
