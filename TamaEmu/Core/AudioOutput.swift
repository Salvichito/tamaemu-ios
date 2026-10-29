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
    private let settingsProvider: () -> (muted: Bool, volume: Float)
    private var started = false

    /// `baseAmplitude` is the loudest the square wave ever gets; `volume`
    /// (from settingsProvider) scales down from there, `muted` silences it
    /// outright. Read once per render callback, not per sample — a
    /// UserDefaults lookup per sample would be wasteful, not per-callback.
    init(
        toneProvider: @escaping () -> (on: Bool, freq: Float),
        settingsProvider: @escaping () -> (muted: Bool, volume: Float)
    ) {
        self.toneProvider = toneProvider
        self.settingsProvider = settingsProvider
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let baseAmplitude: Float = 0.2

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let (on, freq) = self.toneProvider()
            let (muted, volume) = self.settingsProvider()
            let amplitude = muted ? 0 : baseAmplitude * volume
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var localPhase = self.phase
            for frame in 0..<Int(frameCount) {
                var sample: Float = 0
                if on, freq > 0, amplitude > 0 {
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
            applySessionCategory()
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            started = true
        } catch {
            // Audio is secondary to emulation working at all for the MVP;
            // a failure here shouldn't take anything else down.
        }
    }

    /// `.ambient` respects the phone's silent switch (the original
    /// default — a "toy"); `.playback` ignores it (a "game"), at the cost
    /// of ducking/pausing whatever else might be playing, same tradeoff
    /// any game with this option makes. Safe to call again on an already-
    /// active session — e.g. from Settings, while playing — AVAudioSession
    /// picks up a category change without needing the engine restarted.
    func applySessionCategory() {
        let category: AVAudioSession.Category = AppSettings.ignoreSilentSwitch ? .playback : .ambient
        try? AVAudioSession.sharedInstance().setCategory(category, options: [.mixWithOthers])
    }

    func stop() {
        guard started else { return }
        engine.stop()
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
