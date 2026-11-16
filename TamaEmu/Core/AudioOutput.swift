import AVFoundation
import os

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
    /// Guards the small bits of state below, which are touched from the
    /// main thread (start/stop), the emulator thread (tick) and the
    /// session queue. Never held across an AVAudioEngine call.
    private let stateLock = NSLock()
    private var started = false
    /// Whether the engine *should* be rendering right now — see tick().
    private var engineWanted = false
    private var lastActivityNanos: UInt64 = 0
    private var tapInstalled = false
    /// Held across every engine.start()/pause()/stop(), so a stop() from
    /// the main thread can never interleave with a wake-up in flight on
    /// the session queue and leave the engine running after stop().
    private let engineLock = NSLock()
    private static let log = Logger(subsystem: "com.fluorescente.TamaEmu", category: "Audio")

    /// How long after the last beep (or button press) the engine keeps
    /// running before it's paused. The Tama is silent almost all the
    /// time, and a running AVAudioEngine keeps the audio hardware and its
    /// real-time thread awake even while rendering pure silence — measured
    /// at about as much CPU as the emulator itself.
    private static let idleNanos: UInt64 = 2_000_000_000

    /// The loudest the square wave ever gets — the slider at 100%. Just
    /// under full digital scale, leaving a little headroom so the hard
    /// edges of a square wave can't overshoot into clipping if the system
    /// resamples it. The device's own volume buttons scale this like any
    /// other app's sound; nothing here tries to cancel that out (an
    /// earlier version did, by boosting inversely to the system volume —
    /// it ran out of headroom at low device volume and never matched the
    /// system's real volume curve, so loudness ended up unpredictable).
    private static let maxAmplitude: Float = 0.8

    /// `volume` (from volumeProvider) scales down from `maxAmplitude` — at
    /// 0 it's silent. Read once per render callback, not per sample.
    ///
    /// `volume` is squared rather than applied linearly: loudness
    /// perception is roughly logarithmic, so a linear 0...1 scale packs
    /// nearly all the audible change into the slider's last 20% and makes
    /// the rest of its range feel like it's doing nothing. Squaring keeps
    /// the two endpoints the same while spreading the perceptible change
    /// more evenly across the slider.
    init(
        toneProvider: @escaping () -> (on: Bool, freq: Float),
        volumeProvider: @escaping () -> Float
    ) {
        self.toneProvider = toneProvider
        self.volumeProvider = volumeProvider
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let (on, freq) = self.toneProvider()
            let volume = self.volumeProvider()
            let amplitude = Self.maxAmplitude * volume * volume
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

    /// Every AVAudioSession call (`setCategory`, `setActive`) and every
    /// engine wake-up runs on this queue rather than the caller's thread:
    /// AVAudioSession itself warns that calling them synchronously on the
    /// main thread can cause real UI unresponsiveness, and the emulator
    /// thread must never wait on the audio hardware. Every caller already
    /// treats audio as fire-and-forget, best-effort.
    private static let sessionQueue = DispatchQueue(label: "TamaEmu.AudioSession", qos: .userInitiated)

    /// How many AudioOutputs are between start() and stop(). Only touched
    /// on sessionQueue. The session is shared by the whole app, so it's
    /// only ever released when the last one stops.
    private static var runningCount = 0

    func start() {
        stateLock.lock()
        guard !started else { stateLock.unlock(); return }
        started = true
        // Starts warm: a Tama usually plays its jingle right after boot.
        engineWanted = true
        lastActivityNanos = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()
        Self.sessionQueue.async { [weak self] in
            Self.runningCount += 1
            Self.setCategoryNow()
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.syncEngine()
        }
    }

    /// Call from the emulator thread, about once per frame. Costs a lock
    /// and a clock read — no extra wake-ups of its own. Wakes the engine
    /// the moment a tone starts and lets it go back to sleep once the Tama
    /// has been quiet for `idleNanos`.
    ///
    /// A held button counts as activity too: nearly every press is
    /// answered with a beep a few frames later, so waking on the press
    /// gives the audio hardware a head start and the beep's first few
    /// milliseconds aren't lost to its start-up time.
    func tick(buttonsDown: Bool) {
        let active = buttonsDown || toneProvider().on
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        guard started else { stateLock.unlock(); return }
        if active { lastActivityNanos = now }
        let wanted = tapInstalled || now &- lastActivityNanos < Self.idleNanos
        let changed = wanted != engineWanted
        engineWanted = wanted
        stateLock.unlock()
        if changed {
            Self.sessionQueue.async { [weak self] in self?.syncEngine() }
        }
    }

    /// Brings the engine in line with `engineWanted`. Session queue only.
    private func syncEngine() {
        engineLock.lock()
        defer { engineLock.unlock() }
        stateLock.lock()
        let shouldRun = started && engineWanted
        stateLock.unlock()
        if shouldRun, !engine.isRunning {
            // Re-activating an already-active session is a no-op; after a
            // phone call or another app took the session away, this is
            // what gets it back. A failure here (still mid-call, say) is
            // retried naturally on the next beep after an idle period.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Self.log.error("setActive failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try engine.start()
                Self.log.info("engine started, running=\(self.engine.isRunning)")
            } catch {
                Self.log.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if !shouldRun, engine.isRunning {
            // pause(), not stop(): the audio hardware is released either
            // way, but pause keeps the engine's resources prepared so the
            // next wake-up is as quick as it can be.
            engine.pause()
            Self.log.info("engine paused")
        }
    }

    /// The session category is one app-wide choice, not per Tama, so this
    /// is static — Settings calls it directly when a sound option changes
    /// and it takes effect immediately, whichever engine is running.
    static func applySessionCategory() {
        sessionQueue.async {
            setCategoryNow()
            if runningCount > 0 {
                // Needed for a switch to "Pause other audio" to actually
                // pause what's playing now rather than on the next launch.
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }

    /// Two independent choices map onto four session set-ups:
    ///
    ///                      mix with others        pause others
    ///   respect silent     .ambient               .soloAmbient
    ///   ignore silent      .playback + mix        .playback
    private static func setCategoryNow() {
        let session = AVAudioSession.sharedInstance()
        let respectSilent = !AppSettings.ignoreSilentSwitch
        let pauseOthers = AppSettings.pauseOtherAudio
        switch (respectSilent, pauseOthers) {
        case (true, false): try? session.setCategory(.ambient)
        case (true, true): try? session.setCategory(.soloAmbient)
        case (false, false): try? session.setCategory(.playback, options: [.mixWithOthers])
        case (false, true): try? session.setCategory(.playback)
        }
    }

    /// When mixing, deliberately does NOT deactivate the shared
    /// AVAudioSession — only the engine. start()/stop() run on every
    /// scenePhase change, so a session that's fully deactivated here and
    /// reactivated on the next foreground is a *cold* activation each
    /// time, which — even with mixing on — has been observed to still
    /// interrupt whatever else (e.g. Music/Spotify) was playing. Leaving
    /// the session active makes that reactivation a no-op instead.
    ///
    /// With "Pause other audio" on it's the opposite: the session is
    /// handed back, telling the paused app it may resume.
    func stop() {
        stateLock.lock()
        guard started else { stateLock.unlock(); return }
        started = false
        engineWanted = false
        stateLock.unlock()
        engineLock.lock()
        engine.stop()
        engineLock.unlock()
        Self.sessionQueue.async {
            Self.runningCount = max(0, Self.runningCount - 1)
            if Self.runningCount == 0, AppSettings.pauseOtherAudio {
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
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
        // A recording needs a continuous audio track, silence included, so
        // the engine stays awake for as long as the tap is installed.
        setTapInstalled(true)
    }

    func removeRecordingTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        setTapInstalled(false)
    }

    private func setTapInstalled(_ installed: Bool) {
        stateLock.lock()
        tapInstalled = installed
        if installed { engineWanted = true }
        stateLock.unlock()
        Self.sessionQueue.async { [weak self] in self?.syncEngine() }
    }
}
