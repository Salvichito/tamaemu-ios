import SwiftUI

/// The retro screen (Tomomix settings): big pixels and dark scan lines
/// between the rows, like an old low-resolution screen. iOS draws the
/// screen at about 96 pixels across and blows it up without smoothing,
/// plus a still overlay of lines: no per-frame work of our own.
struct TomoRetroScreen: ViewModifier {
    static let settingKey = "tomomix.retroScreen"
    let enabled: Bool
    let side: CGFloat

    /// The same dot grid as the color Tamas' 128×128 screens.
    private static let pixelsAcross: CGFloat = 128

    func body(content: Content) -> some View {
        if enabled, side > 0 {
            // Skies switch to flat color bands (TomoSky), so nothing gets
            // dithered when it's blown up into big pixels.
            LowResolution(content: content.environment(\.tomoRetro, true),
                          pixelsPerPoint: Self.pixelsAcross / side)
                // Exactly the other Tamas' scanlines and glass sheen.
                .lcdScreenEffect(rows: Self.pixelsAcross)
        } else {
            content
        }
    }
}

private struct TomoRetroKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside the Retro Screen: draw flat colors, no smooth gradients.
    var tomoRetro: Bool {
        get { self[TomoRetroKey.self] }
        set { self[TomoRetroKey.self] = newValue }
    }
}

/// Hosts a view in a layer that iOS renders at a low resolution and
/// scales up with "nearest" filtering: hard square pixels.
private struct LowResolution<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let pixelsPerPoint: CGFloat

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.layer.shouldRasterize = true
        host.view.layer.rasterizationScale = pixelsPerPoint
        host.view.layer.magnificationFilter = .nearest
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
        host.view.layer.rasterizationScale = pixelsPerPoint
    }
}

/// Tomomix's own settings, from its ⋯ menu.
struct TomomixSettingsView: View {
    let model: TomomixViewModel
    @AppStorage(TomoRetroScreen.settingKey) private var retro = false
    // Shared with the app's main Settings: one switch for all Tamas.
    @AppStorage(AppSettings.Keys.volume) private var volume = 0.6
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettings.Keys.ignoreSilentSwitch) private var ignoreSilentSwitch = false
    @AppStorage(AppSettings.Keys.appearanceMode) private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    // Tomomix only.
    @AppStorage(TomoCareSettings.notificationsKey) private var notifications = true
    @AppStorage(TomoCareSettings.noDeathsKey) private var noDeaths = false
    @AppStorage(TomoCareSettings.difficultyKey) private var difficulty = TomoCareSettings.Difficulty.classic.rawValue
    @State private var petName = ""
    @State private var playerName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Names") {
                    if model.brain.phase == .alive {
                        nameField("Your tomomix", text: $petName)
                    }
                    nameField("You", text: $playerName)
                }
                Section {
                    Toggle("Sound", isOn: Binding(get: { !model.muted }, set: { model.setMuted(!$0) }))
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: $volume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Toggle("Respect Silent Mode", isOn: Binding(
                        get: { !ignoreSilentSwitch },
                        set: { ignoreSilentSwitch = !$0; AudioOutput.applySessionCategory() }
                    ))
                } header: {
                    Text("Sound & Haptics")
                } footer: {
                    Text("Volume, Haptics and Silent Mode apply to the whole app.")
                }
                Section {
                    Picker("Appearance", selection: $appearanceModeRaw) {
                        ForEach(AppSettings.AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    LabeledContent("Ambient Background", value: "Always on")
                    Toggle("Retro Screen", isOn: $retro)
                    if AppIconChoice.isSupported {
                        NavigationLink("App Icon") {
                            AppIconPickerView()
                        }
                    }
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Tomomix's sky fills your whole screen, included free with Tomomix. Retro Screen adds big pixels and scan lines, like an old screen. Appearance and App Icon apply to the whole app.")
                }
                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { notifications },
                        set: { notifications = $0; model.refreshNotifications() }
                    ))
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(TomoCareSettings.Difficulty.allCases) { d in
                            Text(d.label).tag(d.rawValue)
                        }
                    }
                    Toggle("No Deaths", isOn: $noDeaths)
                } header: {
                    Text("Care")
                } footer: {
                    Text("Notifications let your tomomix call you when it needs something. Easy makes it get hungry, unhappy and sick about 1.5 times slower, with more time to answer a call; Hard about 1.3 times faster. With No Deaths, its life never ends: an old tomomix stays old, and leaving it hungry or unhappy too long makes it sick instead.")
                }
            }
            .navigationTitle("Tomomix Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                petName = model.petName ?? ""
                playerName = TomomixViewModel.playerName ?? ""
            }
            .onDisappear {
                if model.brain.phase == .alive, petName != (model.petName ?? "") { model.rename(pet: petName) }
                model.rename(player: playerName)
            }
        }
    }

    private func nameField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("Name", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, new in
                    if new.count > TomomixViewModel.maxNameLength {
                        text.wrappedValue = String(new.prefix(TomomixViewModel.maxNameLength))
                    }
                }
        }
    }
}
