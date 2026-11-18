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
            TomoGameView(game: game, onSide: { model.tapGameSide(right: $0) })
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

// MARK: - The scene (placeholder art)

private struct TomoScene: View {
    let model: TomomixViewModel

    var body: some View {
        let brain = model.brain
        ZStack {
            switch brain.phase {
            case .star:
                NightSky()
                PulsingStar(birth: brain.birthTime, model: model)
            case .departed:
                NightSky()
                TomoBlob(character: brain.character)
                    .opacity(0.25)
                    .blur(radius: 1)
                Image(systemName: "star.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                    .offset(y: -10)
                VStack {
                    Spacer()
                    Text("Age \(brain.ageYears)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 8)
                }
            case .alive:
                aliveScene(brain)
            }
        }
    }

    @ViewBuilder
    private func aliveScene(_ brain: TomoBrain) -> some View {
        let dark = !brain.lightsOn
        ZStack {
            Color(.systemBackground)
            TomoBlob(character: brain.character)
                .scaleEffect(brain.asleep ? 0.9 : 1)
            VStack {
                HStack {
                    if brain.asleep { Text("Zzz").font(.headline) }
                    Spacer()
                    if brain.sick { Text("☠︎").font(.title2) }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if brain.isOld { Text("old").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    PoopPile(count: brain.poop)
                }
            }
            .padding(10)
            if dark { Color.black.opacity(brain.asleep ? 0.8 : 0.65) }
            if let caption = model.caption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 26)
                }
            }
        }
    }
}

/// Placeholder for each character's art: a colored blob with its name.
private struct TomoBlob: View {
    let character: TomoCharacter

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color.gradient)
                .frame(width: size, height: size)
                .overlay {
                    HStack(spacing: size * 0.18) {
                        Circle().frame(width: size * 0.1)
                        Circle().frame(width: size * 0.1)
                    }
                    .foregroundStyle(.black.opacity(0.7))
                    .offset(y: -size * 0.05)
                }
            Text(character.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var size: CGFloat {
        switch character.stage {
        case .baby: return 44
        case .child: return 58
        case .teen: return 70
        case .adult: return 84
        }
    }

    private var color: Color {
        switch character {
        case .baby: return .pink
        case .childGood: return .mint
        case .childBad: return .brown
        case .teenExcellent, .adult1A, .adult1B, .adult1C, .adult1D: return .yellow
        case .teenGood, .adult2A, .adult2B, .adult2C, .adult2D: return .cyan
        case .teenBad, .adult3A, .adult3B, .adult3C, .adult3D: return .purple
        }
    }
}

/// §10: up to 8 poops, small ones turning big after the 4th.
private struct PoopPile: View {
    let count: Int

    var body: some View {
        let big = max(0, count - 4)
        let small = min(count, 4) - big
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<max(0, small), id: \.self) { _ in Circle().fill(.brown).frame(width: 10, height: 10) }
            ForEach(0..<big, id: \.self) { _ in Circle().fill(.brown).frame(width: 18, height: 18) }
        }
    }
}

private struct NightSky: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.2), Color(red: 0.15, green: 0.1, blue: 0.3)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var rng = TomoRandom(state: 42)
            for _ in 0..<40 {
                let x = rng.unit() * size.width, y = rng.unit() * size.height
                let r = 0.6 + rng.unit() * 1.2
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.4 + rng.unit() * 0.5)))
            }
        }
    }
}

/// §3: the fallen star pulses slowly at first, faster as birth nears.
private struct PulsingStar: View {
    let birth: Date
    let model: TomomixViewModel

    var body: some View {
        TimelineView(.animation) { timeline in
            let left = max(0, birth.timeIntervalSince(model.simTime(at: timeline.date)))
            let total = TomoRules.starPulseSeconds
            let elapsed = total - left
            // Pulse rate rises from 0.5 to 4 per second; integrate for phase.
            let f0 = 0.5, f1 = 4.0
            let phase = 2 * Double.pi * (f0 * elapsed + (f1 - f0) * elapsed * elapsed / (2 * total))
            let glow = (sin(phase) + 1) / 2
            VStack {
                Spacer()
                Image(systemName: "star.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                    .shadow(color: .yellow, radius: 4 + 14 * glow)
                    .scaleEffect(0.85 + 0.25 * glow)
                    .padding(.bottom, 24)
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
                meter("stomach", "Hunger", brain.hunger)
                meter("heart.fill", "Happiness", brain.happiness)
                meter("brain.head.profile", "Discipline", brain.discipline / 25)
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

    private func meter(_ symbol: String, _ name: String, _ level: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 24).accessibilityLabel(name)
            HStack(spacing: 4) {
                ForEach(0..<TomoRules.maxLevel, id: \.self) { i in
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
    let onSide: (Bool) -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
            HStack(spacing: 0) {
                side(right: false)
                side(right: true)
            }
            VStack {
                Text(header).font(.footnote.weight(.semibold)).padding(.top, 8)
                Spacer()
            }
            .allowsHitTesting(false)
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
