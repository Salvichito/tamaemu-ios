import SwiftUI

/// Tomomix prototype: the full play screen with placeholder shapes instead
/// of art. Real art drops into `TomoScene` later; the layout, menus and
/// controls here are the real ones.
struct TomomixView: View {
    @State private var model = TomomixViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingTools = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    TomoScreen(model: model)
                        .frame(maxWidth: 340)
                        .aspectRatio(1, contentMode: .fit)
                    ButtonPad(
                        onPress: { model.press($0) },
                        onRelease: { model.release($0) }
                    )
                    DisclosureGroup("Prototype tools", isExpanded: $showingTools) {
                        TomoDebugPanel(model: model)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Tomomix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.togglePause()
                        } label: {
                            Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
                        }
                        Button(role: .destructive) {
                            model.newStar()
                        } label: {
                            Label("Send a New Shooting Star", systemImage: "sparkles")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.start()
            case .background: model.stop()
            default: break
            }
        }
    }
}

// MARK: - The screen: 8 icons around the scene (§2)

private struct TomoScreen: View {
    let model: TomomixViewModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: 0) {
                iconRow([.food, .light, .game, .medicine], side: side)
                ZStack {
                    TomoScene(model: model)
                    overlay
                }
                // Tap anywhere on the screen to skip or dismiss (§2). The
                // menu items and game sides keep their own taps.
                .contentShape(Rectangle())
                .onTapGesture { model.tapScreen() }
                .frame(height: side * 0.64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, side * 0.04)
                iconRow([.clean, .status, .discipline, .attention], side: side)
            }
            .frame(width: side, height: side)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private func iconRow(_ icons: [TomomixViewModel.Icon], side: CGFloat) -> some View {
        HStack {
            ForEach(icons, id: \.self) { icon in
                TomoIcon(icon: icon, lit: isLit(icon))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapIcon(icon) }
            }
        }
        .frame(height: side * 0.18)
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

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(lit ? Color.primary : Color.primary.opacity(0.18))
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

    var body: some View {
        // Redraws up to 30 times a second, only while this screen is shown.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let now = timeline.date
            let brain = model.brain
            let moment = model.activeMoment(at: now)
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
                TomoStage(brain: brain, moment: moment, now: now, caption: model.caption)
            }
        }
    }
}

// MARK: - Menus

private struct TomoChoiceMenu: View {
    let options: [(symbol: String, label: String)]
    let selected: Int
    let onTap: (Int) -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
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
            Color(.systemBackground)
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
            Color(.systemBackground)
            HStack(spacing: 0) {
                side(right: false)
                side(right: true)
            }
            // The tomomix shows each direction by looking that way; it's
            // drawn looking left and mirrored for right (Animations.md §3).
            GeometryReader { geo in
                let size = geo.size.height * 0.7
                TomoSprite(character: character, pose: pose, mirrored: game.lit == true)
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
        default: return game.lit == nil ? .idle : .look
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
