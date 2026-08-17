import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct NativeOptions {
    var outputPath: String = ""
    var display: Int = 1
    var fps: Double = 60
    var format: String = "mp4"
    var microphone = true
    var microphoneName: String?
    var systemAudio = true
    var cursor = true
    var onlyMic = false
    var onlySystemAudio = false
    var onlyCamera = false
    var camera = false
    var cameraName: String?
    var cameraSize: Double = 0.22
    var cameraPosition = CameraPosition.bottomRight
    var windowName: String?
    var region: String?
    var delaySeconds: Double = 0
    var maxDurationSeconds: Double = 0
    var hevc = false
    var quality: String?
    var scale: Double = 1
    var videoBitrate: Int?
    var audioBitrate: Int?
    var listMics = false
    var listWindows = false
    var listCameras = false
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
            case "--list-windows":
                listWindows = true
            case "--list-cameras":
                listCameras = true
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
            case "--only-system-audio":
                onlySystemAudio = true
                microphone = false
                systemAudio = true
            case "--only-camera":
                onlyCamera = true
                camera = true
                microphone = false
                systemAudio = false
            case "--camera":
                camera = true
            case "--camera-name":
                index += 1
                cameraName = try value(arguments, index, argument)
                camera = true
            case "--camera-size":
                index += 1
                cameraSize = try unitInterval(value(arguments, index, argument), argument)
            case "--camera-position":
                index += 1
                let raw = try value(arguments, index, argument)
                guard let position = CameraPosition(rawValue: raw) else {
                    throw RecorderError.message("Unknown camera position \(raw).")
                }
                cameraPosition = position
            case "--window":
                index += 1
                windowName = try value(arguments, index, argument)
            case "--region":
                index += 1
                region = try value(arguments, index, argument)
            case "--for":
                index += 1
                maxDurationSeconds = try positiveSeconds(value(arguments, index, argument), argument)
            case "--in":
                index += 1
                delaySeconds = try positiveSeconds(value(arguments, index, argument), argument)
            case "--hevc":
                hevc = true
            case "--codec":
                index += 1
                let codec = try value(arguments, index, argument)
                hevc = codec == "hevc"
            case "--quality":
                index += 1
                quality = try value(arguments, index, argument)
            case "--scale":
                index += 1
                scale = try unitInterval(value(arguments, index, argument), argument)
            case "--video-bitrate":
                index += 1
                videoBitrate = try positiveInt(value(arguments, index, argument), argument)
            case "--audio-bitrate":
                index += 1
                audioBitrate = try positiveInt(value(arguments, index, argument), argument)
            default:
                throw RecorderError.message("Unknown native option \(argument).")
            }
            index += 1
        }
        applyQualityPreset()
    }

    var videoCodec: AVVideoCodecType { hevc ? .hevc : .h264 }

    mutating func applyQualityPreset() {
        switch quality {
        case "low":
            if scale == 1 { scale = 0.5 }
            if videoBitrate == nil { videoBitrate = hevc ? 2_500_000 : 4_000_000 }
            if audioBitrate == nil { audioBitrate = 96_000 }
        case "high":
            if videoBitrate == nil { videoBitrate = hevc ? 12_000_000 : 20_000_000 }
            if audioBitrate == nil { audioBitrate = 256_000 }
        default:
            break
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

    private func unitInterval(_ value: String, _ flag: String) throws -> Double {
        guard let number = Double(value), number > 0, number <= 1 else {
            throw RecorderError.message("Option \(flag) must be greater than 0 and no more than 1.")
        }
        return number
    }

    private func positiveSeconds(_ value: String, _ flag: String) throws -> Double {
        guard let number = Double(value), number > 0 else {
            throw RecorderError.message("Option \(flag) must be greater than 0.")
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

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var options: NativeOptions
    private let outputLock = NSLock()
    private let stateLock = NSLock()
    private let cameraLock = NSLock()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var captureSession: AVCaptureSession?
    private var audioFileOutput: AVCaptureAudioFileOutput?
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var streamWriter: StreamWriter?
    private var latestCameraBuffer: CVPixelBuffer?
    private var durationLimitTimer: DispatchSourceTimer?
    private var progressTimer: DispatchSourceTimer?
    private var stopRequested = false
    private var completed = false
    private var completionStatus: Int32 = 0
    private var selectedMicrophoneName: String?
    private var selectedCameraName: String?
    private var selectedWindowTitle: String?
    private var selectedRegionDescription: String?
    private var pendingMP3URL: URL?
    private var captureURL: URL?
    private var discardRequested = false
    private var recordingStartedAt: Date?
    private let sampleQueue = DispatchQueue(label: "com.nocdn.record.samples")

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
        if options.listWindows {
            return await listWindows()
        }
        if options.listCameras {
            return listCameras()
        }

        do {
            installInputHandler()
            try await prepareAndStart()
            return await waitForCompletion()
        } catch {
            emitError(error.localizedDescription)
            if case RecorderError.permission = error {
                return 2
            }
            return 1
        }
    }

    private func prepareAndStart() async throws {
        guard #available(macOS 15.0, *) else {
            throw RecorderError.message("@nocdn/record requires macOS 15 or later.")
        }

        if options.region == "interactive" {
            emit(["event": "region-prompt"])
            let displayID = try await displayIDForPicker()
            let rect = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGRect, Error>) in
                DispatchQueue.main.async {
                    do {
                        continuation.resume(returning: try RegionPicker.pick(displayID: displayID))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            options.region = "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
            if stopRequested {
                finishDiscard()
                return
            }
        }

        if options.delaySeconds > 0 {
            try await runCountdown()
            if stopRequested {
                emit(["event": "discarded", "path": options.outputPath])
                complete(status: 0)
                return
            }
        }

        if options.onlyMic {
            try await startMicrophoneRecording()
        } else if options.onlySystemAudio {
            try await startSystemAudioRecording()
        } else if options.onlyCamera {
            try await startCameraRecording()
        } else {
            try await startScreenRecording()
        }

        startDurationLimitIfNeeded()
    }

    private func runCountdown() async throws {
        var remaining = Int(options.delaySeconds.rounded(.up))
        while remaining > 0 {
            if stopRequested {
                return
            }
            emit(["event": "countdown", "remaining": remaining])
            try await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }
    }

    private func startDurationLimitIfNeeded() {
        guard options.maxDurationSeconds > 0 else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + options.maxDurationSeconds)
        timer.setEventHandler { [weak self] in
            self?.requestStop()
        }
        durationLimitTimer = timer
        timer.resume()
    }

    private func displayIDForPicker() async throws -> CGDirectDisplayID {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard content.displays.indices.contains(options.display - 1) else {
            throw RecorderError.message(
                "Display \(options.display) was not found. Available displays: 1–\(content.displays.count)."
            )
        }
        return content.displays[options.display - 1].displayID
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
        let captureURL: URL
        if outputURL.pathExtension.lowercased() == "mp3" {
            captureURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("record-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
                .appendingPathExtension("caf")
            pendingMP3URL = outputURL
        } else {
            captureURL = outputURL
        }
        self.captureURL = captureURL

        fileOutput.startRecording(
            to: captureURL,
            outputFileType: audioFileType(for: captureURL),
            recordingDelegate: self
        )
    }

    private func startCameraRecording() async throws {
        try await ensureCameraPermission()

        let device = try resolveCameraDevice()
        selectedCameraName = device.localizedName
        let session = AVCaptureSession()
        session.sessionPreset = options.quality == "low" ? .medium : .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderError.message("Could not use the selected camera.")
        }
        session.addInput(input)

        if options.microphone {
            if let microphone = try? resolveMicrophoneDevice(),
               let audioInput = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                selectedMicrophoneName = microphone.localizedName
            }
        }

        let fileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(fileOutput) else {
            throw RecorderError.message("Could not create a camera file output.")
        }
        session.addOutput(fileOutput)
        if options.hevc, let connection = fileOutput.connection(with: .video) {
            fileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }

        captureSession = session
        movieFileOutput = fileOutput
        let outputURL = URL(fileURLWithPath: options.outputPath)
        captureURL = outputURL

        session.startRunning()
        guard session.isRunning else {
            throw RecorderError.message("The camera capture session failed to start.")
        }
        fileOutput.startRecording(to: outputURL, recordingDelegate: self)
    }

    private func startSystemAudioRecording() async throws {
        try ensureScreenPermission()

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let display = try resolveDisplay(in: shareableContent)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let outputURL = URL(fileURLWithPath: options.outputPath)
        let captureURL: URL
        if outputURL.pathExtension.lowercased() == "mp3" {
            captureURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("record-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            pendingMP3URL = outputURL
        } else {
            captureURL = outputURL
        }
        self.captureURL = captureURL

        let writer = try StreamWriter(
            url: captureURL,
            fileType: .m4a,
            width: 2,
            height: 2,
            fps: 30,
            codec: .h264,
            videoBitrate: nil,
            audioBitrate: options.audioBitrate,
            includeVideo: false,
            includeAudio: true
        )
        streamWriter = writer

        let contentStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try contentStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        stream = contentStream
        try await contentStream.startCapture()
        emitStarted()
    }

    private func startScreenRecording() async throws {
        try await ensureMicrophonePermission()
        if options.camera {
            try await ensureCameraPermission()
        }
        try ensureScreenPermission()

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let display = try resolveDisplay(in: shareableContent)
        let filter: SCContentFilter
        if let windowName = options.windowName {
            let window = try findWindow(named: windowName, in: shareableContent)
            selectedWindowTitle = "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Untitled")"
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        var regionRect: CGRect?
        if let region = options.region, region != "interactive" {
            regionRect = try parseRegionRect(region)
            selectedRegionDescription = region
        }

        let pixelSize = scaledPixelSize(for: display, filter: filter, region: regionRect)
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
        if let regionRect {
            configuration.sourceRect = sourceRect(for: regionRect, on: display)
        }

        if options.microphone {
            let device = try resolveMicrophoneDevice()
            configuration.microphoneCaptureDeviceID = device.uniqueID
            selectedMicrophoneName = device.localizedName
        }

        if options.camera {
            try startCameraOverlaySession()
        }

        let usesWriter = options.camera || options.videoBitrate != nil || options.audioBitrate != nil
        let outputURL = URL(fileURLWithPath: options.outputPath)
        captureURL = outputURL
        let contentStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        if usesWriter {
            let writer = try StreamWriter(
                url: outputURL,
                fileType: options.format == "mov" ? .mov : .mp4,
                width: pixelSize.width,
                height: pixelSize.height,
                fps: options.fps,
                codec: options.videoCodec,
                videoBitrate: options.videoBitrate,
                audioBitrate: options.audioBitrate,
                includeVideo: true,
                includeAudio: options.systemAudio || options.microphone
            )
            streamWriter = writer
            try contentStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.systemAudio || options.microphone {
                try contentStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
        } else {
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = outputURL
            recordingConfiguration.videoCodecType = options.videoCodec
            recordingConfiguration.outputFileType = options.format == "mov" ? .mov : .mp4
            let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            try contentStream.addRecordingOutput(output)
            recordingOutput = output
        }

        stream = contentStream
        try await contentStream.startCapture()
        if usesWriter {
            emitStarted()
        }
    }

    private func startCameraOverlaySession() throws {
        let device = try resolveCameraDevice()
        selectedCameraName = device.localizedName
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderError.message("Could not use the selected camera.")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw RecorderError.message("Could not create a camera overlay output.")
        }
        session.addOutput(output)
        captureSession = session
        session.startRunning()
    }

    private func ensureCameraPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw RecorderError.permission(
                    "Camera permission was denied. Grant it in System Settings → Privacy & Security → Camera."
                )
            }
        case .denied, .restricted:
            throw RecorderError.permission(
                "Camera permission is not granted. Grant it in System Settings → Privacy & Security → Camera."
            )
        @unknown default:
            throw RecorderError.message("The camera permission status is unknown.")
        }
    }

    private func resolveDisplay(in content: SCShareableContent) throws -> SCDisplay {
        guard content.displays.indices.contains(options.display - 1) else {
            throw RecorderError.message(
                "Display \(options.display) was not found. Available displays: 1–\(content.displays.count)."
            )
        }
        return content.displays[options.display - 1]
    }

    private func findWindow(named query: String, in content: SCShareableContent) throws -> SCWindow {
        let windows = content.windows.filter { $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 40 }
        if let byID = windows.first(where: { String($0.windowID) == query }) {
            return byID
        }

        func matches(_ window: SCWindow) -> Bool {
            let app = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return app.localizedCaseInsensitiveContains(query) || title.localizedCaseInsensitiveContains(query)
        }

        let hits = windows.filter(matches)
        if hits.count == 1 {
            return hits[0]
        }
        if hits.count > 1 {
            if let exactApp = hits.first(where: {
                ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                return exactApp
            }
            let names = hits.prefix(5).map {
                "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Untitled")"
            }.joined(separator: ", ")
            throw RecorderError.message(
                "Window \"\(query)\" matches more than one window: \(names). Use a more specific title from the windows command."
            )
        }

        throw RecorderError.message(
            "Window \"\(query)\" was not found. Run the windows command to list windows."
        )
    }

    private func parseRegionRect(_ value: String) throws -> CGRect {
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
            throw RecorderError.message("Option --region must look like x,y,w,h.")
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func sourceRect(for region: CGRect, on display: SCDisplay) -> CGRect {
        CGRect(
            x: region.origin.x,
            y: CGFloat(display.height) - region.origin.y - region.height,
            width: region.width,
            height: region.height
        )
    }

    private func scaledPixelSize(
        for display: SCDisplay,
        filter: SCContentFilter,
        region: CGRect?
    ) -> (width: Int, height: Int) {
        let scale = CGFloat(filter.pointPixelScale)
        let pointSize: CGSize
        if let region {
            pointSize = region.size
        } else if options.windowName != nil {
            pointSize = filter.contentRect.size
        } else {
            let native = nativePixelSize(for: display, filter: filter)
            return evenSize(
                width: Int((Double(native.width) * options.scale).rounded()),
                height: Int((Double(native.height) * options.scale).rounded())
            )
        }

        return evenSize(
            width: Int((pointSize.width * scale * options.scale).rounded()),
            height: Int((pointSize.height * scale * options.scale).rounded())
        )
    }

    private func evenSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var evenWidth = max(width, 2)
        var evenHeight = max(height, 2)
        if evenWidth % 2 != 0 { evenWidth -= 1 }
        if evenHeight % 2 != 0 { evenHeight -= 1 }
        return (max(evenWidth, 2), max(evenHeight, 2))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else {
            return
        }
        switch type {
        case .screen:
            cameraLock.lock()
            let camera = latestCameraBuffer
            cameraLock.unlock()
            streamWriter?.appendVideo(
                sampleBuffer: sampleBuffer,
                camera: camera,
                cameraLayout: options.camera
                    ? CameraLayout(size: options.cameraSize, position: options.cameraPosition)
                    : nil
            )
        case .audio:
            streamWriter?.appendAudio(sampleBuffer: sampleBuffer)
        default:
            break
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        cameraLock.lock()
        latestCameraBuffer = image
        cameraLock.unlock()
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
                if line.contains("\"command\":\"discard\"") {
                    self?.requestStop(discard: true)
                } else if line.contains("\"command\":\"stop\"") {
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

    private func requestStop(discard: Bool = false) {
        stateLock.lock()
        if stopRequested {
            stateLock.unlock()
            return
        }
        if discard {
            discardRequested = true
        }
        stopRequested = true
        let discarding = discardRequested
        stateLock.unlock()

        emit(["event": discarding ? "discarding" : "finalizing"])
        progressTimer?.cancel()
        durationLimitTimer?.cancel()
        FileHandle.standardInput.readabilityHandler = nil

        if let audioFileOutput {
            if audioFileOutput.isRecording {
                audioFileOutput.stopRecording()
            } else if discarding {
                captureSession?.stopRunning()
                finishDiscard()
            } else {
                captureSession?.stopRunning()
                complete(status: 1)
            }
            return
        }

        if let movieFileOutput {
            if movieFileOutput.isRecording {
                movieFileOutput.stopRecording()
            } else if discarding {
                captureSession?.stopRunning()
                finishDiscard()
            } else {
                captureSession?.stopRunning()
                complete(status: 1)
            }
            return
        }

        if streamWriter != nil {
            stopStreamThenFinishWriter(discarding: discarding)
            return
        }

        guard let stream else {
            if discarding {
                finishDiscard()
            } else {
                complete(status: 1)
            }
            return
        }

        stream.stopCapture { [weak self] error in
            guard let self else {
                return
            }
            if let error {
                if self.discardRequested {
                    self.finishDiscard()
                    return
                }
                self.emitError(error.localizedDescription)
                self.complete(status: 1)
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
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            ? "granted"
            : "not granted"
        print("Screen & System Audio: \(screenStatus)")
        print("Microphone: \(microphoneStatus)")
        print("Camera: \(cameraStatus)")
        return screenStatus == "granted" && microphoneStatus == "granted" ? 0 : 1
    }

    private func stopStreamThenFinishWriter(discarding: Bool) {
        let finishWriting = { [weak self] in
            Task {
                await self?.completeWriter(discarding: discarding)
            }
            return
        }

        guard let stream else {
            _ = finishWriting()
            return
        }
        stream.stopCapture { [weak self] error in
            if let error, self?.discardRequested != true {
                self?.emitError(error.localizedDescription)
            }
            _ = finishWriting()
        }
    }

    private func completeWriter(discarding: Bool) async {
        await streamWriter?.finish()
        captureSession?.stopRunning()
        if discarding {
            finishDiscard()
            return
        }
        if options.onlySystemAudio, let pending = pendingMP3URL, let captureURL {
            let status = record_encode_audio_file_to_mp3(captureURL.path, pending.path)
            try? FileManager.default.removeItem(at: captureURL)
            if status != 0 {
                emitError("Could not encode the recording as MP3.")
                complete(status: 1)
                return
            }
        }
        if streamWriter?.failed == true {
            emitError(streamWriter?.errorMessage ?? "The recording writer failed.")
            complete(status: 1)
            return
        }
        emit(["event": "saved", "path": options.outputPath])
        complete(status: 0)
    }

    private func emitStarted() {
        var payload: [String: Any] = [
            "event": "started",
            "path": options.outputPath,
        ]
        if let selectedMicrophoneName {
            payload["microphone"] = selectedMicrophoneName
        }
        if let selectedCameraName {
            payload["camera"] = selectedCameraName
        }
        if let selectedWindowTitle {
            payload["window"] = selectedWindowTitle
        }
        if let selectedRegionDescription {
            payload["region"] = selectedRegionDescription
        }
        emit(payload)
        recordingStartedAt = Date()
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
            } else if let startedAt = self.recordingStartedAt, self.streamWriter != nil {
                duration = Date().timeIntervalSince(startedAt)
                bytes = 0
            } else if let audioFileOutput = self.audioFileOutput {
                duration = CMTimeGetSeconds(audioFileOutput.recordedDuration)
                bytes = Int64(audioFileOutput.recordedFileSize)
            } else if let movieFileOutput = self.movieFileOutput {
                duration = CMTimeGetSeconds(movieFileOutput.recordedDuration)
                bytes = Int64(movieFileOutput.recordedFileSize)
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

    private func listWindows() async -> Int32 {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows
                .filter { $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 40 }
                .sorted {
                    let left = $0.owningApplication?.applicationName ?? ""
                    let right = $1.owningApplication?.applicationName ?? ""
                    if left != right {
                        return left.localizedStandardCompare(right) == .orderedAscending
                    }
                    return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
                }
            if windows.isEmpty {
                print("No windows were found.")
                return 1
            }
            for window in windows {
                let app = window.owningApplication?.applicationName ?? "App"
                let title = window.title?.isEmpty == false ? window.title! : "Untitled"
                print("\(app) — \(title)")
            }
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    private func listCameras() -> Int32 {
        let devices = discoverCameras()
        if devices.isEmpty {
            print("No cameras were found.")
            return 1
        }
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        for device in devices {
            if device.uniqueID == defaultID {
                print("\(device.localizedName)  (default)")
            } else {
                print(device.localizedName)
            }
        }
        return 0
    }

    private func resolveCameraDevice() throws -> AVCaptureDevice {
        let devices = discoverCameras()
        if let cameraName = options.cameraName {
            if let exact = devices.first(where: {
                $0.localizedName.localizedCaseInsensitiveCompare(cameraName) == .orderedSame
                    || $0.uniqueID == cameraName
            }) {
                return exact
            }
            let partial = devices.filter { $0.localizedName.localizedCaseInsensitiveContains(cameraName) }
            if partial.count == 1 {
                return partial[0]
            }
            if partial.count > 1 {
                throw RecorderError.message(
                    "Camera \"\(cameraName)\" matches more than one device. Use a more specific name from the cameras command."
                )
            }
            throw RecorderError.message(
                "Camera \"\(cameraName)\" was not found. Run the cameras command to list devices."
            )
        }
        if let defaultCamera = AVCaptureDevice.default(for: .video) {
            return defaultCamera
        }
        if let first = devices.first {
            return first
        }
        throw RecorderError.message("No camera was found. Run the cameras command to list devices.")
    }

    private func discoverCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
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
        case "mp3":
            return .caf
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
        if discardRequested {
            finishDiscard()
            return
        }
        emitError(error.localizedDescription)
        complete(status: 1)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        if discardRequested {
            finishDiscard()
            return
        }
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
        if discardRequested {
            finishDiscard(extra: outputFileURL)
            return
        }

        if let error, !recordingFinishedSuccessfully(error) {
            emitError(error.localizedDescription)
            if pendingMP3URL != nil {
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            complete(status: 1)
            return
        }

        if let mp3URL = pendingMP3URL {
            let status = record_encode_audio_file_to_mp3(
                outputFileURL.path,
                mp3URL.path
            )
            try? FileManager.default.removeItem(at: outputFileURL)
            if status != 0 {
                emitError("Could not encode the recording as MP3.")
                complete(status: 1)
                return
            }
        }

        emit(["event": "saved", "path": options.outputPath])
        complete(status: 0)
    }

    private func recordingFinishedSuccessfully(_ error: Error) -> Bool {
        let nsError = error as NSError
        if let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            return finished
        }
        return false
    }

    private func finishDiscard(extra: URL? = nil) {
        var urls = [URL(fileURLWithPath: options.outputPath)]
        if let pendingMP3URL {
            urls.append(pendingMP3URL)
        }
        if let captureURL {
            urls.append(captureURL)
        }
        if let extra {
            urls.append(extra)
        }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        emit(["event": "discarded", "path": options.outputPath])
        complete(status: 0)
    }
}

@main
struct RecordNativeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            let code = await runNative()
            exit(code)
        }
        app.run()
    }
}

func runNative() async -> Int32 {
    do {
        let options = try NativeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let recorder = Recorder(options: options)
        return await recorder.run()
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
        return 1
    }
}
