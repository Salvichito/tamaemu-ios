import AVFoundation

/// Synthesizes the Tamagotchi's piezo tone as a square wave — the real
/// hardware is a GPIO toggling a buzzer, not a sine source, matching
/// emu.h's "cycle-stamped T0 piezo events". Reads the core's current
/// on/frequency state directly from the emulator thread via the
/// `toneProvider` closure, rather than polling a lock: an aligned
/// Bool/Float read doesn't tear on arm64, the same informal cross-thread
/// pattern the C core and its Android port already rely on elsewhere.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var phase: Double = 0
    private let toneProvider: () -> (on: Bool, freq: Float)
    private var started = false

    init(toneProvider: @escaping () -> (on: Bool, freq: Float)) {
        self.toneProvider = toneProvider
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let amplitude: Float = 0.2

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let (on, freq) = self.toneProvider()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var localPhase = self.phase
            for frame in 0..<Int(frameCount) {
                var sample: Float = 0
                if on, freq > 0 {
                    sample = localPhase < 0.5 ? amplitude : -amplitude
                    localPhase += Double(freq) / sampleRate
                    if localPhase >= 1.0 { localPhase -= 1.0 }
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            self.phase = localPhase
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient)
            try session.setActive(true)
            try engine.start()
            started = true
        } catch {
            // Audio is secondary to emulation working at all for the MVP;
            // a failure here shouldn't take anything else down.
        }
    }

    func stop() {
        guard started else { return }
        engine.stop()
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
