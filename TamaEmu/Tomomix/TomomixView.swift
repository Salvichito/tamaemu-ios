import SwiftUI

/// Tomomix's page in the gallery: the screen, the A/B/C buttons, and (for
/// now) the prototype tools. The gallery starts and stops it like any
/// other Tama's page, and its ⋯ menu holds Pause and a new star.
/// Placeholder shapes stand in until the art drops in (TomomixAnimation).
struct TomomixPageView: View {
    let model: TomomixViewModel
    /// Same title style as the other Tamas' pages (TamaPageView).
    var ambientBackgroundEnabled = false

    var body: some View {
        // Laid out like the other Tamas' pages (TamaPageView): one block,
        // 16 points apart, centered on the page. The Tomomix screen is
        // bigger (up to 320 vs their 280), so the block is lifted by half
        // the difference: the name and buttons land exactly where theirs
        // do, and the extra size goes upward.
        GeometryReader { geo in
            let tomoSide = min(320, geo.size.width - 48)
            let tamaSide = min(280, geo.size.width - 32)
            VStack(spacing: 16) {
                TomoScreen(model: model)
                    .frame(width: tomoSide, height: tomoSide)
                if ambientBackgroundEnabled {
                    Text("Tomomix")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black.opacity(0.25))
                } else {
                    Text("Tomomix")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                ButtonPad(
                    onPress: { model.press($0) },
                    onRelease: { model.release($0) }
                )
            }
            .padding()
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: -max(0, tomoSide - tamaSide) / 2)
        }
    }
}

/// Hosts the game screen in its own UIKit view, so screenshots and video
/// can draw exactly that square (full corners, nothing around it).
private struct TomoCaptureHost<Content: View>: UIViewControllerRepresentable {
    let model: TomomixViewModel
    let content: Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        model.captureView = host.view
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
        model.captureView = host.view
    }
}

/// Sets the screen apart from the full-screen sky behind it, a little like
/// iOS's glass buttons: a big soft halo behind it, a small discreet inner
/// shadow along the top edge, and a thin crisp highlight on the rim.
private struct TomoScreenGlow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white)
                        .blur(radius: side * 0.11)
                        .opacity(0.75)
                }
            }
            .overlay {
                GeometryReader { _ in
                    ZStack {
                        // The glassy rim: bright at the top left, fading round.
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.25), .white.opacity(0.6)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .allowsHitTesting(false)
            }
    }
}

// MARK: - The screen: the room, with 8 icons floating on top (§2)

private struct TomoScreen: View {
    let model: TomomixViewModel
    @AppStorage(TomoRetroScreen.settingKey) private var retro = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Hosted in its own UIKit view so screenshots and video can draw
            // just this square, without the rounded corners cut below.
            TomoCaptureHost(model: model, content: screen(side: side))
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                // On the screen square itself (its frame can be taller than it).
                .modifier(TomoScreenGlow())
        }
    }

    private func screen(side: CGFloat) -> some View {
        ZStack {
            // The room and the tomomix: what the retro screen turns into
            // big pixels. The icons and menus stay sharp on top.
            TomoScene(model: model, side: side)
                // Tap anywhere on the screen to skip or dismiss (§2),
                // catch a shooting star, or poke the tomomix. The
                // icons, menu items and game sides keep their own taps.
                // (Inside the retro layer, as before, so taps still land.)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { tap(at: $0, side: side) }
                .modifier(TomoRetroScreen(enabled: retro, side: side))
            VStack(spacing: 0) {
                iconRow([.food, .light, .game, .medicine], top: true, side: side)
                Spacer(minLength: 0)
                iconRow([.clean, .status, .discipline, .attention], top: false, side: side)
            }
            .opacity(model.waitingForStar ? 0 : 1)
            if case .game(let game) = model.screen {
                TomoGameArrows(game: game, side: side, onSide: { model.tapGameSide(right: $0) })
            } else if model.screen != .main {
                overlay
                    .frame(width: side * 0.8, height: side * 0.56)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            if let prompt = model.prompt {
                TomoNamePrompt(prompt: prompt) { name in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        if prompt == .playerName { model.answerPlayerName(name) } else { model.answerPetName(name) }
                    }
                }
                .frame(width: side * 0.84)
                // Your name: below the star waiting at the top. Its
                // name: above the baby, so you see who you're naming.
                .offset(y: side * (prompt == .playerName ? 0.1 : -0.14))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: model.prompt)
        .frame(width: side, height: side)
        // Any text without its own font is Tomomix lettering too.
        .fontDesign(.rounded)
        .fontWeight(.heavy)
    }

    private func tap(at location: CGPoint, side: CGFloat) {
        if model.paused { model.tapScreen(); return }
        let t = (model.frozenAt ?? Date()).timeIntervalSinceReferenceDate
        if model.waitingForStar {
            // Anywhere on the screen catches the star flying by.
            model.catchPassingStar()
            return
        }
        if TomoScene.petFrame(brain: model.brain, at: t, side: side, outdoors: model.outdoors).contains(location), model.tapPet() { return }
        model.tapScreen()
    }

    /// Light icons over anything dark: the night of the birth and ending,
    /// the room with the light off, and outdoors the night sky behind the
    /// top row (the bottom row is on the grass).
    private func iconsOnDark(top: Bool) -> Bool {
        let brain = model.brain
        if brain.phase != .alive || !brain.lightsOn { return true }
        return model.outdoors && top
            && TomoRoom.timeOfDay(model.simTime(at: Date()), lightsOn: true) == .night
    }

    private func iconRow(_ icons: [TomomixViewModel.Icon], top: Bool, side: CGFloat) -> some View {
        let onDark = iconsOnDark(top: top)
        return HStack {
            ForEach(icons, id: \.self) { icon in
                TomoIcon(icon: icon, lit: isLit(icon), onDark: onDark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapIcon(icon) }
            }
        }
        .frame(height: side * 0.16)
        .padding(.horizontal, side * 0.04)
    }

    private func isLit(_ icon: TomomixViewModel.Icon) -> Bool {
        icon == .attention ? model.brain.attention : model.cursor == icon
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.screen {
        case .main:
            EmptyView()
        case .food(let choice):
            TomoChoiceMenu(
                options: [("fork.knife", "Meal", "tomo-meal-1"), ("birthday.cake", "Snack", "tomo-snack-1")],
                selected: choice,
                onTap: { model.tapFood(snack: $0 == 1) }
            )
        case .lights(let choice):
            TomoChoiceMenu(
                options: [("lightbulb.fill", "On", "tomo-light-on"), ("lightbulb", "Off", "tomo-light-off")],
                selected: choice,
                onTap: { model.tapLights(on: $0 == 0) }
            )
        case .status:
            TomoStatusView(brain: model.brain, name: model.petName ?? "")
        case .game:
            EmptyView()                       // played in the room (TomoGameArrows)
        }
    }
}

private struct TomoIcon: View {
    let icon: TomomixViewModel.Icon
    let lit: Bool
    /// Over the night sky or a dark room, the icons turn light.
    let onDark: Bool

    /// The ink color of the room drawing.
    private static let ink = Color(red: 0x1D / 255, green: 0x17 / 255, blue: 0x3C / 255)

    var body: some View {
        let color = onDark ? Color.white : Self.ink
        Group {
            // Your drawing (`tomo-icon-*`, one color, tinted here), or a stand-in.
            if let art = TomoArt.item("tomo-icon-\(artName)") {
                Image(art).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
            }
        }
        .foregroundStyle(color.opacity(lit ? 1 : 0.28))
    }

    private var artName: String {
        switch icon {
        case .food: return "food"
        case .light: return "light"
        case .game: return "game"
        case .medicine: return "medicine"
        case .clean: return "clean"
        case .status: return "status"
        case .discipline: return "discipline"
        case .attention: return "attention"
        }
    }

    private var symbol: String {
        switch icon {
        case .food: return "fork.knife"
        case .light: return "lightbulb.fill"
        case .game: return "gamecontroller.fill"
        case .medicine: return "cross.case.fill"
        case .clean: return "shower.fill"
        case .status: return "chart.bar.fill"
        case .discipline: return "hand.raised.fill"
        case .attention: return "exclamationmark.bubble.fill"
        }
    }
}

// MARK: - The scene (TomomixAnimation.swift draws it)

private struct TomoScene: View {
    let model: TomomixViewModel
    let side: CGFloat

    /// Where the tomomix lives inside the room drawing (596 x 596): it
    /// stands with its feet in the middle of the rug (y = 415) and walks
    /// around on it. Fractions of the square's side.
    /// Outdoors (`tomo-outdoors`, same 596 square) it stands in the middle
    /// of the meadow, whose top edge is at y = 338.
    private struct Floor {
        let feet: CGFloat
        let center: CGFloat
        static let indoors = Floor(feet: 415.0 / 596, center: 306.0 / 596)
        static let outdoors = Floor(feet: 428.0 / 596, center: 298.0 / 596)
        /// The outdoors drawing is made to line up with the room, so the
        /// tomomix stands in the same place in both.
        static func at(outdoors: Bool) -> Floor { .indoors }
        /// The stage keeps the size it had in the prototype: 80% of the
        /// width, 64% of the height (the character is 86% of that).
        static let width: CGFloat = 0.8
        static let height: CGFloat = 0.64
    }

    var body: some View {
        // Redraws up to 30 times a second, only while this screen is shown.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.paused || !model.isRunning)) { timeline in
            // Paused: draw the frozen instant, so nothing moves (§16).
            let now = model.frozenAt ?? timeline.date
            let brain = model.brain
            let moment = model.activeMoment(at: now)
            ZStack {
                switch brain.phase {
                case .star:
                    TomoBirthScene(
                        bornAt: brain.birthTime,
                        simNow: model.simTime(at: now),
                        now: now,
                        intro: moment?.isBirthIntro == true ? moment : nil,
                        waiting: model.waitingForStar,
                        caught: model.caughtStar,
                        caughtAt: model.caughtAt
                    )
                case .departed:
                    TomoEndingScene(
                        character: brain.character,
                        name: model.petName ?? "",
                        ageYears: brain.ageYears,
                        now: now,
                        hintUntil: model.endingHintUntil,
                        transition: moment.map { $0.progress(at: now) }
                    )
                case .alive:
                    TomoRoom(simNow: model.simTime(at: now), lightsOn: brain.lightsOn, asleep: brain.asleep,
                             outdoors: model.outdoors)
                    stage(brain: brain, moment: moment, now: now)
                    if !brain.lightsOn && !model.outdoors {
                        Color(red: 0x1D / 255, green: 0x17 / 255, blue: 0x3C / 255).opacity(brain.asleep ? 0.7 : 0.55)
                    }
                    // Born or evolving: the white of the burst, edge to edge.
                    if let m = moment, m.whiteout(at: now) > 0 {
                        Color.white.opacity(m.whiteout(at: now)).allowsHitTesting(false)
                    }
                }
                if model.paused {
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill").font(.system(size: 34))
                        Text("Paused").font(.tomo(.footnote))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)                    // a square
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: side, height: side)
        }
    }

    /// Roughly where the tomomix's body is at time `t`, for poking it:
    /// a little bigger than the drawing so it's easy to hit.
    static func petFrame(brain: TomoBrain, at t: TimeInterval, side: CGFloat, outdoors: Bool) -> CGRect {
        let floor = Floor.at(outdoors: outdoors)
        let size = side * Floor.height * 0.86
        // Sick, it stands still in the middle (see TomoStage.liveLook).
        let walk = brain.sick ? (x: 0.0, depth: 0) : {
            let w = TomoStage.wander(at: t * (brain.isOld ? 0.7 : 1), slow: false, jumpChance: 0)
            return (x: w.x, depth: w.depth)
        }()
        let x = side * floor.center + walk.x * side * Floor.width
        let feet = side * floor.feet + CGFloat(walk.depth) * size * 0.035
        let body = size * brain.character.placeholderScale + size * 0.12
        return CGRect(x: x - body * 0.6, y: feet - body, width: body * 1.2, height: body + size * 0.06)
    }

    private func stage(brain: TomoBrain, moment: TomoMoment?, now: Date) -> some View {
        let floor = Floor.at(outdoors: model.outdoors)
        let h = side * Floor.height
        // The sprite fills 86% of the stage's height and its feet sit at
        // y = 442 of its 512 artboard; line those feet up with the rug.
        let size = h * 0.86
        let bottom = side * floor.feet + size * (1 - TomoArtboard.baseline)
        var game: TomomixViewModel.GameState?
        if case .game(let g) = model.screen { game = g }
        // Prototype tools' Effect: loop that effect on the live stage.
        let effect = model.preview.effect
        let shownMoment = effect?.moment(now: now, character: model.preview.character ?? brain.character) ?? (effect == nil ? moment : nil)
        return TomoStage(brain: brain, moment: shownMoment, now: now, caption: model.caption, preview: model.preview,
                         forceMark: effect?.mark, outdoors: model.outdoors, game: game)
            .frame(width: side * Floor.width, height: h)
            .position(x: side * floor.center, y: bottom - h / 2)
    }
}

// MARK: - Name questions (§3)

private struct TomoNamePrompt: View {
    let prompt: TomomixViewModel.Prompt
    let onAnswer: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(prompt == .playerName ? "Your name?" : "Name your baby")
                .font(.tomo(.headline))
            TextField(prompt == .playerName ? "Your name" : "Its name", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { if !trimmed.isEmpty { onAnswer(trimmed) } }
                .onChange(of: text) { _, new in
                    if new.count > TomomixViewModel.maxNameLength { text = String(new.prefix(TomomixViewModel.maxNameLength)) }
                }
            HStack(spacing: 10) {
                Button("Skip") { onAnswer(nil) }
                    .buttonStyle(.bordered)
                Button("OK") { onAnswer(trimmed) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
            .font(.tomo(.footnote))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { focused = true }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Menus

private struct TomoChoiceMenu: View {
    /// With `art` drawn, the choice is just the drawing, no words.
    let options: [(symbol: String, label: String, art: String?)]
    let selected: Int
    let onTap: (Int) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 18) {
                ForEach(options.indices, id: \.self) { i in
                    Group {
                        if let art = options[i].art.flatMap({ TomoArt.item($0) }) {
                            // Full-color drawings (food) as they are; one-color
                            // ones (the light) in the ink color.
                            Image(art).resizable().scaledToFit()
                                .foregroundStyle(Color(red: 0x1D / 255, green: 0x17 / 255, blue: 0x3C / 255))
                                .frame(width: 92, height: 92)
                                .accessibilityLabel(options[i].label)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: options[i].symbol).font(.system(size: 30))
                                Text(options[i].label).font(.tomo(.footnote))
                            }
                        }
                    }
                    .frame(width: 96, height: 96)
                    .background {
                        // The chosen one sits in your scribbled circle (`tomo-selection`).
                        if i == selected {
                            if let art = TomoArt.item("tomo-selection") {
                                Image(art).resizable().scaledToFit().frame(width: 112, height: 112)
                            } else {
                                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.2))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 2))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(i) }
                }
            }
        }
    }
}

/// §15: everything on one screen, three meters with 5 levels each.
private struct TomoStatusView: View {
    let brain: TomoBrain
    let name: String

    /// Tomomix colors: full → empty.
    private static let green = Color(red: 0x7B / 255, green: 0xC1 / 255, blue: 0x88 / 255)
    private static let yellow = Color(red: 0xFF / 255, green: 0xEA / 255, blue: 0x60 / 255)
    private static let orange = Color(red: 0xFF / 255, green: 0xA3 / 255, blue: 0x22 / 255)
    private static let red = Color(red: 0xEC / 255, green: 0x46 / 255, blue: 0x46 / 255)
    private static let blue = Color(red: 0x59 / 255, green: 0x89 / 255, blue: 0xA3 / 255)

    var body: some View {
        // Sized from the card itself (80% of the game screen wide), so it
        // keeps the mockup's proportions on every phone.
        GeometryReader { geo in
            let side = geo.size.width / 0.8
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !name.isEmpty {
                    Text(name)
                        .font(.system(size: side * 0.085, weight: .heavy, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.horizontal, side * 0.04)
                }
                Spacer(minLength: 0)
                VStack(spacing: side * 0.022) {
                    meter("tomo-meter-hunger", "fork.knife", "Hunger", brain.hunger, of: TomoRules.maxLevel,
                          color: Self.stepColor, side: side)
                    meter("tomo-meter-happy", "heart.fill", "Happiness", brain.happiness, of: TomoRules.maxLevel,
                          color: Self.stepColor, side: side)
                    meter("tomo-meter-discipline", "brain.head.profile", "Discipline", brain.discipline / TomoRules.disciplineStep,
                          of: 100 / TomoRules.disciplineStep, color: { _ in Self.blue }, side: side)
                }
                .padding(.horizontal, side * 0.06)
                Spacer(minLength: 0)
                Text("\(weightText), \(brain.ageYears == 1 ? "1 year old" : "\(brain.ageYears) years old")")
                    .font(.tomo(.callout))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Hunger and happiness: each step keeps its own color, red → orange →
    /// yellow → green from the left, so a fuller bar reaches further into green.
    private static func stepColor(_ step: Int) -> Color {
        switch step {
        case 0: return red
        case 1: return orange
        case 2: return yellow
        default: return green
        }
    }

    /// In the phone's own unit (kg, or lb where that's used).
    private var weightText: String {
        Measurement(value: Double(brain.weight), unit: UnitMass.kilograms)
            .formatted(.measurement(width: .abbreviated, usage: .personWeight,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private func meter(_ art: String, _ symbol: String, _ name: String, _ level: Int, of segments: Int, color: @escaping (Int) -> Color, side: CGFloat) -> some View {
        HStack(spacing: side * 0.03) {
            Group {
                if let icon = TomoArt.item(art) {
                    // One color, following the text: dark in light mode, light in dark mode.
                    Image(icon).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: side * 0.07, height: side * 0.07)
            // Drawn bigger than the space it takes, so nothing else moves.
            .scaleEffect(1.6)
            .accessibilityLabel(name)
            HStack(spacing: segments > 5 ? side * 0.008 : side * 0.013) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: side * 0.01)
                        .fill(i < level ? color(i) : Color.secondary.opacity(0.2))
                        .frame(height: side * 0.043)
                }
            }
        }
    }
}

/// §6 Follow Me: the two directions, lit while shown or pressed.
/// Follow Me (§6), played right in the room (or outdoors): the tomomix
/// itself shows the directions, and the two arrows (`tomo-arrow`, drawn
/// pointing left, mirrored for right) sit at the sides. Each half of the
/// screen between the icon rows is a big tap target for its arrow.
private struct TomoGameArrows: View {
    let game: TomomixViewModel.GameState
    let side: CGFloat
    let onSide: (Bool) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                half(right: false)
                half(right: true)
            }
        }
        .frame(width: side, height: side)
    }

    private func half(right: Bool) -> some View {
        let lit = game.lit == right
        let arrow = side * 0.17
        return ZStack {
            Color.clear
            Group {
                if let art = TomoArt.item("tomo-arrow") {
                    Image(art).resizable().scaledToFit()
                } else {
                    Image(systemName: "arrowshape.left.fill").resizable().scaledToFit()
                }
            }
            .frame(width: arrow, height: arrow)
            .scaleEffect(x: (right ? -1 : 1) * (lit ? 1.18 : 1), y: lit ? 1.18 : 1)
            .opacity(lit ? 1 : 0.6)
            .frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
            .padding(.horizontal, side * 0.1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: side * 0.66)
        .contentShape(Rectangle())
        .onTapGesture { onSide(right) }
    }
}

// MARK: - Prototype tools

private struct TomoDebugPanel: View {
    @Bindable var model: TomomixViewModel
    @State private var showingMarkCheck = ProcessInfo.processInfo.environment["TOMO_DEBUG_MARKGRID"] != nil

    var body: some View {
        let b = model.brain
        VStack(alignment: .leading, spacing: 12) {
            Button("Check mark placement (all characters)") { showingMarkCheck = true }
                .sheet(isPresented: $showingMarkCheck) { TomoMarkCheck() }
            previewRow("Character", value: model.preview.character?.label ?? "Live",
                       step: { stepCharacter($0) }, live: { model.preview.character = nil })
            previewRow("Pose", value: model.preview.drawing?.name ?? "Live",
                       step: { stepDrawing($0) }, live: { model.preview.drawing = nil })
            previewRow("Effect", value: model.preview.effect?.rawValue ?? "Live",
                       step: { stepEffect($0) }, live: { model.preview.effect = nil })
            Picker("Speed", selection: $model.speed) {
                Text("1×").tag(1.0)
                Text("10×").tag(10.0)
                Text("60×").tag(60.0)
                Text("600×").tag(600.0)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("+10 min") { model.skipAhead(minutes: 10) }
                Button("+1 hour") { model.skipAhead(minutes: 60) }
                Button("+8 hours") { model.skipAhead(minutes: 480) }
            }
            .buttonStyle(.bordered)
            Group {
                Text("Time: \(model.simNow.formatted(date: .abbreviated, time: .shortened))\(model.paused ? " (paused)" : "")")
                Text("\(b.phase.rawValue) · \(b.character.label) · age \(b.ageYears) · weight \(b.weight)")
                Text("Care mistakes C=\(b.careMistakes) · Discipline mistakes D=\(b.disciplineMistakes)")
                Text("Hunger \(b.hunger)/4 (next drop \(b.hungerCountdown) min) · Happy \(b.happiness)/4 (\(b.happyCountdown) min)")
                Text("Call deadline: \(b.careDeadline.map { "\($0) min" } ?? "—") · Misbehaving: \(b.misbehaving ? "yes" : "no")")
                Text("Grows/ages in \(b.lifetimeLeft) min · Healthy \(Int(b.healthyLeft)) min · Poop \(b.poop)")
                Text("Asleep \(b.asleep ? "yes" : "no") · Lights \(b.lightsOn ? "on" : "off")\(b.isOld ? " · old" : "")\(b.departureCause.map { " · ended: \($0.rawValue)" } ?? "")")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    /// ‹ value › with a Live button, for previewing art (not saved).
    private func previewRow(_ title: String, value: String,
                            step: @escaping (Int) -> Void, live: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
            Text(value).font(.subheadline.monospaced()).frame(minWidth: 96)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
            Button("Live", action: live).font(.caption)
        }
        .buttonStyle(.bordered)
    }

    private func stepCharacter(_ by: Int) {
        let all = TomoCharacter.allCases
        let current = model.preview.character ?? model.brain.character
        let i = all.firstIndex(of: current) ?? 0
        model.preview.character = all[(i + by + all.count) % all.count]
    }

    private func stepEffect(_ by: Int) {
        let all = TomoPreview.Effect.allCases
        let i = model.preview.effect.flatMap { e in all.firstIndex(of: e) } ?? (by > 0 ? -1 : 0)
        model.preview.effect = all[(i + by + all.count) % all.count]
    }

    private func stepDrawing(_ by: Int) {
        let all = TomoPreview.drawings
        let i = model.preview.drawing.flatMap { d in all.firstIndex(of: d) } ?? (by > 0 ? -1 : 0)
        model.preview.drawing = all[(i + by + all.count) % all.count]
    }
}


/// Prototype tools: every character in the room, standing still with its
/// sick face, with the needy spiral, sick ball or thought bubble on, drawn
/// by the real stage, to check where the marks land on all of them at once.
private struct TomoMarkCheck: View {
    @State private var mark = "needy"
    private let brain = TomoBrain(now: Date())

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mark", selection: $mark) {
                Text("Spiral").tag("needy")
                Text("Ball").tag("sick")
                Text("Bubble").tag("bubble")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(TomoCharacter.allCases, id: \.self) { c in
                        cell(c)
                    }
                }
                .padding(4)
            }
        }
        .padding(.top)
    }

    private func cell(_ c: TomoCharacter) -> some View {
        GeometryReader { geo in
            let side = geo.size.width
            // Same layout as the game screen (TomoScene, indoors).
            let h = side * 0.64, size = h * 0.86
            let bottom = side * 415 / 596 + size * (1 - TomoArtboard.baseline)
            TimelineView(.animation(minimumInterval: 1.0 / 10)) { t in
                ZStack {
                    TomoRoom(simNow: Date(), lightsOn: true, asleep: false)
                    TomoStage(brain: brain, moment: nil, now: t.date, caption: nil,
                              preview: TomoPreview(character: c, drawing: TomoPreview.drawings[6]),
                              forceMark: mark)
                        .frame(width: side * 0.8, height: h)
                        .position(x: side * 306 / 596, y: bottom - h / 2)
                    Text(c.rawValue).font(.caption2).padding(2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(width: side, height: side)
                .clipped()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}


extension Font {
    /// Tomomix's own lettering: SF Pro Rounded, Heavy, at a text style's size.
    static func tomo(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded, weight: .heavy)
    }
}
