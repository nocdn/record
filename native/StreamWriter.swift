import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class StreamWriter: NSObject {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var firstTime: CMTime?

    let width: Int
    let height: Int

    init(
        url: URL,
        fileType: AVFileType,
        width: Int,
        height: Int,
        fps: Double,
        codec: AVVideoCodecType,
        videoBitrate: Int?,
        audioBitrate: Int?,
        includeVideo: Bool,
        includeAudio: Bool
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.width = width
        self.height = height
        writer = try AVAssetWriter(url: url, fileType: fileType)

        if includeVideo {
            var compression: [String: Any] = [
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
            if let videoBitrate {
                compression[AVVideoAverageBitRateKey] = videoBitrate
            }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.message("Could not create a video writer.")
            }
            writer.add(input)
            videoInput = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
            )
        } else {
            videoInput = nil
            adaptor = nil
        }

        if includeAudio {
            var audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ]
            if let audioBitrate {
                audioSettings[AVEncoderBitRateKey] = audioBitrate
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        super.init()
    }

    func appendVideo(sampleBuffer: CMSampleBuffer, camera: CVPixelBuffer?, cameraLayout: CameraLayout?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let videoInput, let adaptor else {
            return
        }
        guard let screen = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        startIfNeeded(at: time)
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else {
            return
        }

        if let camera, let cameraLayout, let composed = compose(screen: screen, camera: camera, layout: cameraLayout) {
            adaptor.append(composed, withPresentationTime: time)
            return
        }
        adaptor.append(screen, withPresentationTime: time)
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let audioInput else {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        startIfNeeded(at: time)
        guard writer.status == .writing, audioInput.isReadyForMoreMediaData else {
            return
        }
        audioInput.append(sampleBuffer)
    }

    func finish() async {
        let writerToFinish: AVAssetWriter? = lock.withLock {
            if finished {
                return nil
            }
            finished = true
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            return writer
        }

        if let writerToFinish, writerToFinish.status == .writing {
            await writerToFinish.finishWriting()
        }
    }

    var failed: Bool {
        writer.status == .failed
    }

    var errorMessage: String? {
        writer.error?.localizedDescription
    }

    private func startIfNeeded(at time: CMTime) {
        if started {
            return
        }
        started = true
        firstTime = time
        writer.startWriting()
        writer.startSession(atSourceTime: time)
    }

    private func compose(screen: CVPixelBuffer, camera: CVPixelBuffer, layout: CameraLayout) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screen)
        let cameraImage = CIImage(cvPixelBuffer: camera)
        let videoWidth = CGFloat(width)
        let videoHeight = CGFloat(height)
        let camWidth = max(64, videoWidth * layout.size)
        let aspect = cameraImage.extent.height / max(cameraImage.extent.width, 1)
        let camHeight = camWidth * aspect
        let margin: CGFloat = 16
        let x: CGFloat
        let y: CGFloat
        switch layout.position {
        case .bottomRight:
            x = videoWidth - camWidth - margin
            y = margin
        case .bottomLeft:
            x = margin
            y = margin
        case .topRight:
            x = videoWidth - camWidth - margin
            y = videoHeight - camHeight - margin
        case .topLeft:
            x = margin
            y = videoHeight - camHeight - margin
        }

        let scaledCamera = cameraImage.transformed(
            by: CGAffineTransform(
                scaleX: camWidth / max(cameraImage.extent.width, 1),
                y: camHeight / max(cameraImage.extent.height, 1)
            )
        ).transformed(by: CGAffineTransform(translationX: x, y: y))

        let output = scaledCamera.composited(over: screenImage.cropped(to: CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)))
        guard let buffer = makePixelBuffer() else {
            return nil
        }
        ciContext.render(output, to: buffer)
        return buffer
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}

struct CameraLayout {
    var size: CGFloat
    var position: CameraPosition
}

enum CameraPosition: String {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
    case topRight = "top-right"
    case topLeft = "top-left"
}
