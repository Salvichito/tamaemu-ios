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
    private let volumeProvider: () -> Float
    private var started = false

    /// iOS scales every app's output by the hardware volume on top of
    /// whatever the app renders — there's no way to opt out of that. So
    /// `TamaEmu`'s own slider is made to mean an absolute loudness, not one
    /// relative to wherever the hardware volume happens to sit, by reading
    /// the current system output level here and pre-amplifying inversely to
    /// it in the render callback below. Updated via KVO on
    /// `AVAudioSession.outputVolume`, which only fires while the session is
    /// active — set up from `start()`, after `setActive(true)` succeeds.
    private var systemVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var systemVolumeObservation: NSKeyValueObservation?

    /// `baseAmplitude` is the loudest the square wave ever gets; `volume`
    /// (from volumeProvider) scales down from there — at 0 it's silent.
    /// Read once per render callback, not per sample — a UserDefaults
    /// lookup per sample would be wasteful, not per-callback.
    ///
    /// `volume` is squared rather than applied linearly: loudness
    /// perception is roughly logarithmic, so a linear 0...1 scale packs
    /// nearly all the audible change into the slider's last 20% and makes
    /// the rest of its range feel like it's doing nothing. Squaring keeps
    /// the two endpoints the same (0 stays silent, 1 stays at
    /// `baseAmplitude`) while spreading the perceptible change more evenly
    /// across the slider.
    init(
        toneProvider: @escaping () -> (on: Bool, freq: Float),
        volumeProvider: @escaping () -> Float
    ) {
        self.toneProvider = toneProvider
        self.volumeProvider = volumeProvider
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let baseAmplitude: Float = 0.2

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let (on, freq) = self.toneProvider()
            let volume = self.volumeProvider()
            let target = baseAmplitude * volume * volume
            // Counteract the hardware volume's own scaling by pre-amplifying
            // inversely to it, clamped so the result never exceeds full
            // digital scale (would clip) and never divides by a
            // near-silent system volume (would spike the gain absurdly).
            let compensation = 1 / max(self.systemVolume, 0.05)
            let amplitude = min(target * compensation, 1.0)
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

    /// All three AVAudioSession calls below (`setCategory`, `setActive`
    /// true/false) are only ever invoked from the main actor in this
    /// codebase — but AVAudioSession itself warns that calling them
    /// synchronously there, especially setCategory while the session is
    /// already active, can cause real UI unresponsiveness, and
    /// specifically suggests its async activate/deactivate API instead.
    /// They're pushed onto a background queue here rather than made
    /// `async` outright, since every caller (EmulatorEngine.start/stop,
    /// live Settings changes) already treats audio as fire-and-forget,
    /// best-effort — matching the existing "audio is secondary" stance
    /// below rather than threading `async`/`await` through call sites
    /// that have no other reason to need it.
    private static let sessionQueue = DispatchQueue(label: "TamaEmu.AudioSession", qos: .userInitiated)

    func start() {
        guard !started else { return }
        started = true
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.setCategoryNow()
                try AVAudioSession.sharedInstance().setActive(true)
                try self.engine.start()
                if self.systemVolumeObservation == nil {
                    self.systemVolumeObservation = AVAudioSession.sharedInstance()
                        .observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
                            self?.systemVolume = session.outputVolume
                        }
                }
            } catch {
                // Audio is secondary to emulation working at all for the
                // MVP; a failure here shouldn't take anything else down.
            }
        }
    }

    /// `.ambient` respects the phone's silent switch (the original
    /// default — a "toy"); `.playback` ignores it (a "game"), with
    /// `.mixWithOthers` so it plays over whatever else is already going
    /// rather than silencing it. Safe to call again on an already-active
    /// session — e.g. from Settings, while playing — AVAudioSession picks
    /// up a category change without needing the engine restarted.
    func applySessionCategory() {
        Self.sessionQueue.async { [weak self] in self?.setCategoryNow() }
    }

    private func setCategoryNow() {
        let category: AVAudioSession.Category = AppSettings.ignoreSilentSwitch ? .playback : .ambient
        try? AVAudioSession.sharedInstance().setCategory(category, options: [.mixWithOthers])
    }

    /// Deliberately does NOT deactivate the shared AVAudioSession — only
    /// the engine, which is what actually costs CPU/battery while
    /// backgrounded. start()/stop() run on every scenePhase change, so a
    /// session that's fully deactivated here and reactivated on the next
    /// foreground is a *cold* activation each time, which — even with
    /// `.mixWithOthers` already set on the category — has been observed to
    /// still interrupt whatever else (e.g. Music/Spotify) was playing.
    /// Leaving the session active makes that reactivation a no-op instead.
    func stop() {
        guard started else { return }
        started = false
        engine.stop()
    }

    /// The exact format the render callback above outputs on — ScreenRecorder
    /// reads this to configure a matching AAC encoder before tapping this
    /// node for a video's audio track.
    var outputFormat: AVAudioFormat { engine.mainMixerNode.outputFormat(forBus: 0) }

    /// Taps the mixer node non-destructively — sourceNode above keeps
    /// rendering to the speaker exactly as before — so ScreenRecorder can
    /// route the Tama's own sound into a video's audio track. Never the
    /// microphone; no extra permission is needed for this.
    func installRecordingTap(format: AVAudioFormat, bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func removeRecordingTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }
}
