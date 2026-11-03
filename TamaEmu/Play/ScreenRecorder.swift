import AVFoundation
import SwiftUI

/// Renders the LCD exactly as TamaPageView shows it — same sharp-pixels/
/// scanline AppStorage settings LCDView itself reads — into a single
/// square image. Shared by the screenshot button and, once per frame, by
/// ScreenRecorder below, so both capture paths stay visually identical to
/// whatever's actually on screen.
@MainActor
func renderLCDSnapshot(image: CGImage?, side: CGFloat, scale: CGFloat = 3) -> CGImage? {
    let renderer = ImageRenderer(content: LCDView(image: image).frame(width: side, height: side))
    renderer.scale = scale
    return renderer.cgImage
}

/// Captures the LCD into an H.264/AAC video file for as long as the record
/// button is held, with the Tama's own audio tapped straight off
/// AudioOutput's mixer node — never the microphone, so no extra
/// permission is ever requested for this.
///
/// `start`/`stop`/`captureFrame` only ever run on the main actor (the same
/// pattern PlayViewModel's own display timer uses). `appendAudio` is the
/// one method that doesn't: it's called directly from AVAudioEngine's
/// real-time render thread via the tap installed in `start`, and touches
/// only this recorder's own audio bookkeeping, never `viewModel` or
/// anything else main-actor-isolated.
///
/// `@unchecked Sendable` because the Timer and audio-tap closures above
/// are themselves `@Sendable` (Foundation/AVFoundation's own doing, not a
/// choice made here) and need to capture `self` to call back into this
/// recorder — the actual cross-thread safety is the manual, per-property
/// reasoning in each method's own doc comment, the same informal pattern
/// AudioOutput uses for its render callback.
final class ScreenRecorder: @unchecked Sendable {
    enum RecorderError: Error {
        case cannotStart
    }

    private let side: CGFloat = 512
    private let frameRate: Int32 = 30

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var frameCount: Int64 = 0
    private var audioSampleCount: Int64 = 0
    private var audioSampleRate: Double = 44_100
    private var captureTimer: Timer?
    private weak var viewModel: PlayViewModel?

    @discardableResult
    @MainActor
    func start(viewModel: PlayViewModel) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(side),
            AVVideoHeightKey: Int(side),
        ])
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(side),
                kCVPixelBufferHeightKey as String: Int(side),
            ]
        )

        let audioFormat = viewModel.audioFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioFormat.sampleRate,
            AVNumberOfChannelsKey: Int(audioFormat.channelCount),
            AVEncoderBitRateKey: 64_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.cannotStart
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.cannotStart
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor
        self.audioInput = audioInput
        self.frameCount = 0
        self.audioSampleCount = 0
        self.audioSampleRate = audioFormat.sampleRate
        self.viewModel = viewModel

        viewModel.installRecordingTap(format: audioFormat, bufferSize: 1_024) { [weak self] buffer, _ in
            self?.appendAudio(buffer)
        }
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(frameRate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureFrame() }
        }

        return url
    }

    @MainActor
    private func captureFrame() {
        guard let videoInput, videoInput.isReadyForMoreMediaData,
              let pool = pixelBufferAdaptor?.pixelBufferPool,
              let lcdImage = viewModel?.lcdImage,
              let image = renderLCDSnapshot(image: lcdImage, side: side)
        else { return }

        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: CMTime(value: frameCount, timescale: frameRate))
        frameCount += 1
    }

    /// Runs on AVAudioEngine's real-time render thread, not the main actor
    /// — touches only `audioInput`/`audioSampleCount`/`audioSampleRate`,
    /// each written by this thread alone for the life of one recording.
    private func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }

        var asbd = buffer.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(audioSampleRate)),
            presentationTimeStamp: CMTime(value: audioSampleCount, timescale: Int32(audioSampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return }

        audioInput.append(sampleBuffer)
        audioSampleCount += Int64(buffer.frameLength)
    }

    /// Stops capture. `discard: true` throws the partial recording away
    /// (used when the hold never produced anything worth keeping) instead
    /// of finishing the file; otherwise finalizes it and hands back the
    /// finished file's URL via `completion` (nil on failure either way).
    @MainActor
    func stop(discard: Bool, completion: @escaping (URL?) -> Void) {
        captureTimer?.invalidate()
        captureTimer = nil
        viewModel?.removeRecordingTap()
        viewModel = nil

        guard let writer, !discard else {
            writer?.cancelWriting()
            completion(nil)
            return
        }
        let url = writer.outputURL
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        // finishWriting's completion handler is itself `@Sendable`
        // (AVFoundation's doing), so it can't capture the local `writer`
        // constant directly — only `self` (capturing it here, `[self]`,
        // rather than the usual `[weak self]`, is deliberate: this
        // recorder has nothing left to do after this closure runs, so
        // there's no reason to let it deallocate before finishWriting's
        // callback fires). `self` is fine to cross that boundary because
        // the class itself is declared `@unchecked Sendable` above.
        writer.finishWriting { [self] in
            // `status` (a plain enum, Sendable for free) is what actually
            // crosses into the Task below — never `writer`/`self` itself.
            let status = self.writer?.status
            // finishWriting's handler fires on an arbitrary queue, never
            // guaranteed to be the main thread — unlike captureFrame's
            // Timer, this genuinely needs a hop back, not just an
            // assumeIsolated assertion.
            Task { @MainActor in
                completion(status == .completed ? url : nil)
            }
        }
    }
}
