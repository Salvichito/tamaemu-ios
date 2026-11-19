import SwiftUI

/// Tomomix's page in the gallery: the screen, the A/B/C buttons, and (for
/// now) the prototype tools. The gallery starts and stops it like any
/// other Tama's page, and its ⋯ menu holds Pause and a new star.
/// Placeholder shapes stand in until the art drops in (TomomixAnimation).
struct TomomixPageView: View {
    let model: TomomixViewModel
    @State private var showingTools = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                TomoScreen(model: model)
                    .frame(maxWidth: 320)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 24)
                Text("Tomomix")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ButtonPad(
                    onPress: { model.press($0) },
                    onRelease: { model.release($0) }
                )
                DisclosureGroup("Prototype tools", isExpanded: $showingTools) {
                    TomoDebugPanel(model: model)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .padding(.top, 70)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - The screen: the room, with 8 icons floating on top (§2)

private struct TomoScreen: View {
    let model: TomomixViewModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                TomoScene(model: model, side: side)
                    // Tap anywhere on the screen to skip or dismiss (§2). The
                    // icons, menu items and game sides keep their own taps.
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapScreen() }
                if model.screen != .main {
                    overlay
                        .frame(width: side * 0.8, height: side * 0.56)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
                VStack(spacing: 0) {
                    iconRow([.food, .light, .game, .medicine], side: side)
                    Spacer(minLength: 0)
                    iconRow([.clean, .status, .discipline, .attention], side: side)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
    }

    private func iconRow(_ icons: [TomomixViewModel.Icon], side: CGFloat) -> some View {
        HStack {
            ForEach(icons, id: \.self) { icon in
                TomoIcon(icon: icon, lit: isLit(icon), onDark: model.brain.phase != .alive || !model.brain.lightsOn)
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
                options: [("fork.knife", "Meal"), ("birthday.cake", "Snack")],
                selected: choice,
                onTap: { model.tapFood(snack: $0 == 1) }
            )
        case .lights(let choice):
            TomoChoiceMenu(
                options: [("lightbulb.fill", "On"), ("lightbulb", "Off")],
                selected: choice,
                onTap: { model.tapLights(on: $0 == 0) }
            )
        case .status:
            TomoStatusView(brain: model.brain)
        case .game(let game):
            TomoGameView(game: game, character: model.brain.character, onSide: { model.tapGameSide(right: $0) })
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
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(color.opacity(lit ? 1 : 0.28))
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
    private enum Floor {
        static let feet: CGFloat = 415.0 / 596
        static let center: CGFloat = 306.0 / 596
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
                        intro: moment?.isBirthIntro == true ? moment : nil
                    )
                case .departed:
                    TomoEndingScene(
                        character: brain.character,
                        ageYears: brain.ageYears,
                        now: now,
                        transition: moment.map { $0.progress(at: now) }
                    )
                case .alive:
                    TomoRoom(simNow: model.simTime(at: now), lightsOn: brain.lightsOn, asleep: brain.asleep)
                    stage(brain: brain, moment: moment, now: now)
                    if !brain.lightsOn {
                        Color.black.opacity(brain.asleep ? 0.7 : 0.55)
                    }
                }
                if model.paused {
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill").font(.system(size: 34))
                        Text("Paused — tap to resume").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: side, height: side)
        }
    }

    private func stage(brain: TomoBrain, moment: TomoMoment?, now: Date) -> some View {
        let h = side * Floor.height
        // The sprite fills 86% of the stage's height and its feet sit at
        // y = 442 of its 512 artboard; line those feet up with the rug.
        let size = h * 0.86
        let bottom = side * Floor.feet + size * (1 - TomoArtboard.baseline)
        return TomoStage(brain: brain, moment: moment, now: now, caption: model.caption)
            .frame(width: side * Floor.width, height: h)
            .position(x: side * Floor.center, y: bottom - h / 2)
    }
}

// MARK: - Menus

private struct TomoChoiceMenu: View {
    let options: [(symbol: String, label: String)]
    let selected: Int
    let onTap: (Int) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 18) {
                ForEach(options.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        Image(systemName: options[i].symbol).font(.system(size: 30))
                        Text(options[i].label).font(.footnote.weight(.semibold))
                    }
                    .frame(width: 84, height: 84)
                    .background(i == selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(i == selected ? Color.accentColor : .clear, lineWidth: 2))
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

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                meter("fork.knife", "Hunger", brain.hunger, of: TomoRules.maxLevel)
                meter("heart.fill", "Happiness", brain.happiness, of: TomoRules.maxLevel)
                meter("brain.head.profile", "Discipline", brain.discipline / TomoRules.disciplineStep, of: 100 / TomoRules.disciplineStep)
                HStack {
                    Text("Age \(brain.ageYears)")
                    Spacer()
                    Text("Weight \(brain.weight)")
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 22)
        }
    }

    private func meter(_ symbol: String, _ name: String, _ level: Int, of segments: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 24).accessibilityLabel(name)
            HStack(spacing: segments > 5 ? 2 : 4) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < level ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 14)
                }
            }
        }
    }
}

/// §6 Follow Me: the two directions, lit while shown or pressed.
private struct TomoGameView: View {
    let game: TomomixViewModel.GameState
    let character: TomoCharacter
    let onSide: (Bool) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                side(right: false)
                side(right: true)
            }
            // The tomomix shows each direction by looking that way, with
            // its own look-right drawing when there is one (Animations.md §3).
            GeometryReader { geo in
                let size = geo.size.height * 0.7
                TomoSprite(character: character, pose: pose)
                    .frame(width: size, height: size)
                    .position(x: geo.size.width / 2, y: geo.size.height - size / 2)
            }
            .allowsHitTesting(false)
            VStack {
                Text(header).font(.footnote.weight(.semibold)).padding(.top, 8)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    private var pose: TomoPose {
        switch game.step {
        case .result(let score, _): return score > 0 ? .happy : .sad
        default: return game.lit == nil ? .idle : game.lit == true ? .lookRight : .look
        }
    }

    private var header: String {
        switch game.step {
        case .showing: return "Round \(game.round) — watch"
        case .input(let i): return "Round \(game.round) — your turn (\(i + 1)/\(game.sequence.count))"
        case .result(let score, let reward):
            let name = score == 5 ? "Perfect" : score >= 3 ? "Good" : score >= 1 ? "OK" : "Fail"
            return "\(name)! \(score)/5 · +\(reward) happiness · press any button"
        }
    }

    private func side(right: Bool) -> some View {
        let lit = game.lit == right
        return Image(systemName: right ? "arrowshape.right.fill" : "arrowshape.left.fill")
            .font(.system(size: 44))
            .foregroundStyle(lit ? Color.accentColor : Color.secondary.opacity(0.25))
            .scaleEffect(lit ? 1.15 : 1)
            .animation(.easeOut(duration: 0.1), value: lit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { onSide(right) }
    }
}

// MARK: - Prototype tools

private struct TomoDebugPanel: View {
    @Bindable var model: TomomixViewModel

    var body: some View {
        let b = model.brain
        VStack(alignment: .leading, spacing: 12) {
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
}
