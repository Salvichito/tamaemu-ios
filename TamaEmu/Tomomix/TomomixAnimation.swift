import SwiftUI
import UIKit

// Tomomix animations: poses (drawings) + motion (the app), as described in
// Docs/Tomomix/Animations.md. Real art drops in by file name; anything not
// drawn yet falls back to another pose, or to a placeholder face.

// MARK: - Poses (Animations.md §3)

enum TomoPose: String, CaseIterable {
    case idle, blink, eat, refuse, happy, sad, sleep, sick, look, call, pout, scolded
    /// Its own drawing, for characters that shouldn't simply be flipped
    /// (curly hair, a bow on one side). Without one, `look` is mirrored.
    case lookRight = "look-right"

    var frameCount: Int { self == .idle || self == .eat ? 2 : 1 }

    /// What to show when this pose hasn't been drawn yet (Animations.md §3).
    /// A missing second frame falls back to the first.
    var fallback: TomoPose? {
        switch self {
        case .blink: return .idle
        case .sleep: return .eat            // eat-1 doubles as sleeping
        case .pout, .scolded: return .refuse
        case .call: return .sad
        case .sad: return .sick
        default: return nil
        }
    }
}

extension TomoCharacter {
    /// File-name slug (Animations.md §6).
    var slug: String {
        switch self {
        case .baby: return "baby"
        case .childGood: return "child-good"
        case .childBad: return "child-bad"
        case .teenExcellent: return "teen-excellent"
        case .teenGood: return "teen-good"
        case .teenBad: return "teen-bad"
        default: return label.lowercased()          // "1a" … "3d"
        }
    }

    /// Placeholder body size inside the shared square artboard.
    var placeholderScale: CGFloat {
        switch stage {
        case .baby: return 0.38
        case .child: return 0.48
        case .teen: return 0.58
        case .adult: return 0.7
        }
    }

    var placeholderColor: Color {
        switch self {
        case .baby: return .pink
        case .childGood: return .mint
        case .childBad: return .brown
        case .teenExcellent, .adult1A, .adult1B, .adult1C, .adult1D: return .yellow
        case .teenGood, .adult2A, .adult2B, .adult2C, .adult2D: return .cyan
        case .teenBad, .adult3A, .adult3B, .adult3C, .adult3D: return .purple
        }
    }
}

// MARK: - Finding real art

@MainActor
enum TomoArt {
    private static var exists: [String: Bool] = [:]

    static func has(_ name: String) -> Bool {
        if let known = exists[name] { return known }
        let found = UIImage(named: name) != nil
        exists[name] = found
        return found
    }

    static func name(_ character: TomoCharacter, _ pose: TomoPose, _ frame: Int) -> String {
        let base = "tomo-\(character.slug)-\(pose.rawValue)"
        return pose.frameCount > 1 ? "\(base)-\(min(max(frame, 1), pose.frameCount))" : base
    }

    /// The drawing to show, following the fallback chain, or nil when this
    /// character has no art yet (then the placeholder draws the pose).
    static func imageName(_ character: TomoCharacter, _ pose: TomoPose, _ frame: Int) -> String? {
        var current: TomoPose? = pose
        var currentFrame = frame
        while let p = current {
            let n = name(character, p, currentFrame)
            if has(n) { return n }
            if currentFrame > 1, has(name(character, p, 1)) { return name(character, p, 1) }
            current = p.fallback
            currentFrame = 1
        }
        return nil
    }

    /// A shared item (prop, effect, scene), e.g. "tomo-meal-2", if drawn.
    /// A name without a frame number also finds frame 1, so `tomo-zzz`
    /// uses `tomo-zzz-1` until each frame is animated on its own.
    static func item(_ name: String) -> String? {
        if has(name) { return name }
        return has(name + "-1") ? name + "-1" : nil
    }
}

// MARK: - Moments (Animations.md §4)

struct TomoMoment {
    enum Kind {
        case eat(snack: Bool, bites: Int)
        case refuse
        case happy
        case sad
        case medicine(cured: Bool)
        case clean(poop: Int)
        case poop
        case scold
        case evolve(from: TomoCharacter, to: TomoCharacter)
        case birthIntro
        case burst
        case depart(TomoCharacter)
    }

    let kind: Kind
    let start: Date

    init(_ kind: Kind, at start: Date = Date()) {
        self.kind = kind
        self.start = start
    }

    var duration: TimeInterval {
        switch kind {
        case .eat(_, let bites): return 0.4 + 0.5 * Double(bites)
        case .refuse: return 1
        case .happy, .sad, .medicine, .clean, .scold, .burst: return 1.5
        case .poop: return 1
        case .evolve, .depart: return 3
        case .birthIntro: return TomoRules.birthIntroSeconds
        }
    }

    func elapsed(at date: Date) -> TimeInterval { max(0, date.timeIntervalSince(start)) }
    func progress(at date: Date) -> Double { min(1, elapsed(at: date) / duration) }
    func isOver(at date: Date) -> Bool { date.timeIntervalSince(start) >= duration }

    var isBirthIntro: Bool { if case .birthIntro = kind { return true } else { return false } }
}

// MARK: - A character drawing

/// The shared 512 × 512 artboard every character pose is drawn on.
enum TomoArtboard {
    /// Where the feet rest: y = 442 of 512, as in the Baby's drawings.
    static let baseline: CGFloat = 442.0 / 512
}

struct TomoSprite: View {
    let character: TomoCharacter
    let pose: TomoPose
    var frame = 1
    var mirrored = false

    var body: some View {
        // Looking right: its own drawing if there is one, otherwise the
        // left-looking one flipped.
        let ownRight = pose == .lookRight ? TomoArt.imageName(character, .lookRight, 1) : nil
        let shown: TomoPose = pose == .lookRight && ownRight == nil ? .look : pose
        let flip = mirrored != (pose == .lookRight && ownRight == nil)
        let art = ownRight ?? TomoArt.imageName(character, shown, frame)
        Group {
            if let art {
                Image(art).resizable().scaledToFit()
            } else {
                TomoPlaceholder(character: character, pose: shown, frame: frame)
            }
        }
        .scaleEffect(x: flip ? -1 : 1, y: 1)
        .overlay {
            if art == nil {
                TomoPlaceholderLabel(character: character)
            }
        }
    }
}

/// Stand-in for a pose: a colored body on the artboard's baseline, with a
/// face that changes per pose.
private struct TomoPlaceholder: View {
    let character: TomoCharacter
    let pose: TomoPose
    let frame: Int

    var body: some View {
        Canvas { ctx, size in
            let g = ctx
            let s = size.width
            var bw = s * character.placeholderScale
            var bh = bw
            switch pose {
            case .idle where frame == 2: bw *= 1.04; bh *= 0.96
            case .eat where frame == 2: bw *= 1.08
            case .sleep: bh *= 0.8; bw *= 1.08
            case .scolded: bh *= 0.92
            default: break
            }
            let body = CGRect(x: (s - bw) / 2, y: s * TomoArtboard.baseline - bh, width: bw, height: bh)
            g.fill(Path(ellipseIn: body), with: .color(character.placeholderColor))
            if pose == .sick { g.fill(Path(ellipseIn: body), with: .color(.green.opacity(0.35))) }

            let ink = GraphicsContext.Shading.color(.black.opacity(0.75))
            let shift: CGFloat = pose == .look ? -bw * 0.14 : pose == .refuse ? bw * 0.12 : 0
            let ey = body.minY + bh * 0.42
            let er = max(2, bw * 0.05)
            let eyes = [body.midX - bw * 0.17 + shift, body.midX + bw * 0.17 + shift]
            let lw = max(1.5, bw * 0.035)
            func line(_ pts: [CGPoint]) {
                var p = Path()
                p.addLines(pts)
                g.stroke(p, with: ink, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }

            for x in eyes {
                switch pose {
                case .blink, .sleep, .scolded:
                    line([CGPoint(x: x - er, y: ey), CGPoint(x: x + er, y: ey)])
                case .happy:
                    line([CGPoint(x: x - er, y: ey + er * 0.5), CGPoint(x: x, y: ey - er * 0.6), CGPoint(x: x + er, y: ey + er * 0.5)])
                case .sick:
                    line([CGPoint(x: x - er, y: ey - er), CGPoint(x: x + er, y: ey + er)])
                    line([CGPoint(x: x - er, y: ey + er), CGPoint(x: x + er, y: ey - er)])
                default:
                    g.fill(Path(ellipseIn: CGRect(x: x - er, y: ey - er, width: er * 2, height: er * 2)), with: ink)
                }
            }
            if pose == .pout {
                line([CGPoint(x: eyes[0] - er * 1.4, y: ey - er * 2.4), CGPoint(x: eyes[0] + er, y: ey - er * 1.4)])
                line([CGPoint(x: eyes[1] + er * 1.4, y: ey - er * 2.4), CGPoint(x: eyes[1] - er, y: ey - er * 1.4)])
            }
            if pose == .sad {
                let tear = CGRect(x: eyes[1] - er * 0.5, y: ey + er * 1.4, width: er, height: er * 1.6)
                g.fill(Path(ellipseIn: tear), with: .color(.blue.opacity(0.7)))
            }

            let my = body.minY + bh * 0.66
            let mx = body.midX + shift
            let mw = bw * 0.12
            switch pose {
            case .eat where frame == 1, .call:
                let r = pose == .call ? mw * 0.5 : mw * 0.8
                g.fill(Path(ellipseIn: CGRect(x: mx - r, y: my - r, width: r * 2, height: r * 1.8)), with: ink)
            case .eat:
                line([CGPoint(x: mx - mw * 0.6, y: my), CGPoint(x: mx + mw * 0.6, y: my)])
            case .happy:
                var p = Path()
                p.move(to: CGPoint(x: mx - mw, y: my - mw * 0.3))
                p.addQuadCurve(to: CGPoint(x: mx + mw, y: my - mw * 0.3), control: CGPoint(x: mx, y: my + mw))
                g.stroke(p, with: ink, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .sad, .scolded, .refuse:
                var p = Path()
                p.move(to: CGPoint(x: mx - mw * 0.8, y: my + mw * 0.3))
                p.addQuadCurve(to: CGPoint(x: mx + mw * 0.8, y: my + mw * 0.3), control: CGPoint(x: mx, y: my - mw * 0.6))
                g.stroke(p, with: ink, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            case .pout:
                line([CGPoint(x: mx - mw * 0.5, y: my + mw * 0.2), CGPoint(x: mx + mw * 0.5, y: my)])
            case .sick:
                line([CGPoint(x: mx - mw, y: my), CGPoint(x: mx - mw * 0.5, y: my - mw * 0.3), CGPoint(x: mx, y: my),
                      CGPoint(x: mx + mw * 0.5, y: my - mw * 0.3), CGPoint(x: mx + mw, y: my)])
            default:
                break
            }
        }
    }
}

/// The placeholder's name tag, drawn outside the mirroring so it stays
/// readable when the tomomix faces right.
private struct TomoPlaceholderLabel: View {
    let character: TomoCharacter

    var body: some View {
        GeometryReader { geo in
            let bw = geo.size.width * character.placeholderScale
            Text(character.label)
                .font(.system(size: max(7, bw * 0.1), weight: .semibold))
                .foregroundStyle(.black.opacity(0.4))
                .position(x: geo.size.width / 2, y: geo.size.height * 0.98 - bw * 0.15)
        }
    }
}

// MARK: - The living scene

/// Everything about how the tomomix looks at one instant.
private struct TomoLook {
    var character: TomoCharacter
    var pose: TomoPose = .idle
    var frame = 1
    var mirrored = false
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
    var silhouette = false
}

/// The tomomix in its room: base behavior (wandering, blinking, sleeping,
/// sick, calling, pouting) with the current moment layered on top.
struct TomoStage: View {
    let brain: TomoBrain
    let moment: TomoMoment?
    let now: Date
    let caption: String?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let size = h * 0.86
            let look = self.look(width: w, size: size)
            let head = CGPoint(x: w / 2 + look.x, y: h - size * (look.character.placeholderScale + 0.2) + look.y)
            // The room, the sky and the lights-off dimming are drawn by the
            // screen around this stage (TomoRoom); this is only the floor area.
            ZStack {
                poopLayer(width: w, height: h)

                if let m = moment, case .eat(let snack, let bites) = m.kind {
                    foodProp(snack: snack, bites: bites, moment: m)
                        .frame(width: size * 0.22, height: size * 0.22)
                        .position(x: w / 2 + size * 0.36, y: h - size * 0.12)
                }

                TomoSprite(character: look.character, pose: look.pose, frame: look.frame, mirrored: look.mirrored)
                    .frame(width: size, height: size)
                    .colorMultiply(look.silhouette ? .black : .white)
                    .scaleEffect(look.scale, anchor: .bottom)
                    .opacity(look.opacity)
                    .position(x: w / 2 + look.x, y: h - size / 2 + look.y)

                effects(head: head, size: size, width: w, height: h)

                momentOverlay(width: w, height: h)

                if let caption {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: Pose and motion

    private func look(width w: CGFloat, size: CGFloat) -> TomoLook {
        // Old tomomixis move a little slower (Animations.md §4).
        let t = now.timeIntervalSinceReferenceDate * (brain.isOld ? 0.7 : 1)
        var l = TomoLook(character: brain.character)

        if brain.asleep {
            l.pose = .sleep
        } else if brain.sick {
            l.pose = .sick
        } else if brain.misbehaving {
            l.pose = .pout
        } else if brain.attention {
            l.pose = .call
        } else {
            l.frame = Int(t * 2).isMultiple(of: 2) ? 1 : 2
            if t.truncatingRemainder(dividingBy: 3.7) < 0.15 { l.pose = .blink; l.frame = 1 }
        }

        // Wander around while awake, the classic way: no sliding, it hops
        // one step at a time, a couple of times a second, for a retro feel.
        // It isn't flipped when walking right: some characters aren't
        // symmetric (curly hair).
        if !brain.asleep {
            // Happy jumps (happiness above half), only while it's just
            // hanging around: not sick, calling or misbehaving.
            let calm = l.pose == .idle || l.pose == .blink
            let chance = !calm ? 0 : brain.happiness >= TomoRules.maxLevel ? 0.6 : brain.happiness * 2 > TomoRules.maxLevel ? 0.35 : 0
            let walk = Self.wander(at: t, slow: brain.sick, jumpChance: chance)
            l.x = walk.x * w
            // Each depth step is a small move up (further back) or down.
            l.y = CGFloat(walk.depth) * size * 0.035
            switch walk.jump {
            case .up: l.pose = .happy; l.frame = 1; l.y -= size * 0.12
            case .landed: l.pose = .happy; l.frame = 1
            case nil: break
            }
        }

        guard let m = moment else { return l }
        let e = m.elapsed(at: now)
        let p = m.progress(at: now)
        // Moments happen center stage, facing the player.
        l.x = 0
        l.y = 0
        l.mirrored = false
        l.frame = 1
        switch m.kind {
        case .eat:
            if e >= 0.4 { l.pose = .eat; l.frame = Int((e - 0.4) / 0.25).isMultiple(of: 2) ? 1 : 2 } else { l.pose = .idle }
        case .refuse:
            l.pose = .refuse
            l.x = sin(e * 30) * size * 0.04 * (1 - p)
        case .happy:
            l.pose = .happy
            l.y = -abs(sin(p * .pi * 3)) * size * 0.1
        case .sad:
            l.pose = .sad
        case .medicine(let cured):
            if e < 0.75 { l.pose = .sick } else if cured {
                l.pose = .happy
                l.y = -abs(sin((e - 0.75) / 0.75 * .pi * 2)) * size * 0.08
            } else { l.pose = .sick }
        case .clean, .poop:
            l.pose = .idle
        case .scold:
            if e < 0.4 { l.pose = .idle } else {
                l.pose = .scolded
                l.x = sin(e * 25) * size * 0.02 * (1 - p)
            }
        case .evolve(let from, let to):
            if p < 0.3 {
                l.character = from
                l.pose = .idle
            } else if p < 0.7 {
                l.character = Int(e * 8).isMultiple(of: 2) ? from : to
                l.pose = .idle
                l.silhouette = true
            } else {
                l.character = to
                l.pose = .happy
                l.y = -abs(sin((p - 0.7) / 0.3 * .pi * 2)) * size * 0.08
            }
        case .burst:
            l.pose = .happy
            l.scale = p < 0.45 ? 0.001 : CGFloat(min(1, (p - 0.45) / 0.35))
        case .birthIntro, .depart:
            break
        }
        return l
    }

    /// The wandering tomomix at time `t`: where it stands (a fraction of
    /// the stage width from its center) and whether it's mid-jump. Every
    /// few seconds it picks a random spot on a grid of steps, hops there
    /// one step per beat, then waits. A happy one sometimes jumps while
    /// it waits (`jumpChance` per walk). Worked out from the time alone,
    /// so a paused screen stays put.
    static func wander(at t: TimeInterval, slow: Bool, jumpChance: Double) -> (x: CGFloat, depth: Int, jump: JumpBeat?) {
        let beat = slow ? 1.0 : 0.5                // seconds per hop
        let stepsPerLeg = 8                         // beats between new spots
        let reach = 4                               // steps left or right of center
        let stepSize: CGFloat = 0.06                // of the stage width

        let beats = Int((t / beat).rounded(.down))
        let leg = beats / stepsPerLeg
        let into = beats - leg * stepsPerLeg
        let from = Int(shuffle(leg - 1) % UInt64(2 * reach + 1)) - reach
        let to = Int(shuffle(leg) % UInt64(2 * reach + 1)) - reach
        let distance = to - from
        let moved = min(abs(distance), into) * (distance < 0 ? -1 : 1)
        let x = CGFloat(from + moved) * stepSize

        // A little forward or back too (depth -2…2), stepping at the same
        // time as sideways, so it doesn't walk along a single line.
        let depthReach = 2
        func depthSpot(_ n: Int) -> Int { Int(shuffle(n &* 31 &+ 5) % UInt64(2 * depthReach + 1)) - depthReach }
        let fromDepth = depthSpot(leg - 1)
        let depthDistance = depthSpot(leg) - fromDepth
        let depth = fromDepth + min(abs(depthDistance), into) * (depthDistance < 0 ? -1 : 1)
        // Wait only once both have arrived.
        let travel = max(abs(distance), abs(depthDistance))

        // A jump takes two beats of the wait after arriving: up, then a
        // smile back on the ground.
        let wait = stepsPerLeg - travel
        guard jumpChance > 0, wait >= 2 else { return (x, depth, nil) }
        let roll = shuffle(leg &* 7919 &+ 1)
        guard Double(roll % 1000) / 1000 < jumpChance else { return (x, depth, nil) }
        let start = travel + Int((roll / 1000) % UInt64(wait - 1))
        switch into - start {
        case 0: return (x, depth, .up)
        case 1: return (x, depth, .landed)
        default: return (x, depth, nil)
        }
    }

    enum JumpBeat { case up, landed }

    /// A fixed shuffle of whole numbers: the same answer every time.
    private static func shuffle(_ n: Int) -> UInt64 {
        var z = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: Props and effects

    private func poopLayer(width w: CGFloat, height h: CGFloat) -> some View {
        var count = brain.poop
        var sweep: Double?
        var drop: Double = 0
        if let m = moment {
            switch m.kind {
            case .clean(let n): count = n; sweep = m.progress(at: now)
            case .poop: drop = 1 - m.progress(at: now)
            default: break
            }
        }
        return ZStack {
            if sweep.map({ $0 < 0.6 }) ?? true {
                PoopPile(count: count, newestDrop: drop)
                    .position(x: w * 0.82, y: h * 0.86)
            }
            if let sweep {
                Group {
                    if let art = TomoArt.item("tomo-clean") {
                        Image(art).resizable().scaledToFit()
                    } else {
                        Image(systemName: "shower.fill").resizable().scaledToFit().foregroundStyle(.blue)
                    }
                }
                .frame(width: h * 0.3, height: h * 0.3)
                .position(x: -w * 0.1 + w * 1.2 * sweep, y: h * 0.72)
            }
        }
    }

    @ViewBuilder
    private func foodProp(snack: Bool, bites: Int, moment m: TomoMoment) -> some View {
        let e = m.elapsed(at: now)
        let eaten = max(0, Int((e - 0.4) / 0.5) + (e >= 0.4 ? 1 : 0))
        let left = 1 - Double(min(eaten, bites)) / Double(bites)
        let stage = left > 0.6 ? 1 : left > 0 ? 2 : 3              // whole, half, crumbs
        if let art = TomoArt.item("tomo-\(snack ? "snack" : "meal")-\(stage)") {
            Image(art).resizable().scaledToFit()
        } else {
            Image(systemName: snack ? "birthday.cake.fill" : "fork.knife.circle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(snack ? Color.pink : Color.orange)
                .scaleEffect(stage == 1 ? 1 : stage == 2 ? 0.6 : 0.25, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func effects(head: CGPoint, size: CGFloat, width w: CGFloat, height h: CGFloat) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        ZStack {
            if brain.asleep, moment == nil {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    effect("tomo-zzz", fallback: Text("Z").font(.system(size: 12 + CGFloat(i) * 4, weight: .bold)))
                        .opacity(1 - phase)
                        .position(x: head.x + size * 0.15 + CGFloat(phase) * size * 0.15, y: head.y - CGFloat(phase) * size * 0.25)
                }
            }
            if brain.sick {
                effect("tomo-skull", fallback: Text("☠︎").font(.title2))
                    .position(x: w - 22, y: 22)
            }
            if !brain.asleep, brain.misbehaving, moment == nil {
                effect("tomo-anger", fallback: Image(systemName: "flame.fill").foregroundStyle(.orange))
                    .position(x: head.x + size * 0.2, y: head.y - size * 0.05)
            } else if !brain.asleep, brain.attention, !brain.sick, moment == nil {
                effect("tomo-call", fallback: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red))
                    .position(x: head.x + size * 0.2, y: head.y - size * 0.05)
            } else if !brain.asleep, !brain.sick, moment == nil,
                      brain.hunger == 1 || brain.happiness == 1 {
                // §4: one step left on a meter, so it thinks about what
                // it'll soon want, before it starts calling.
                TomoThoughtBubble(meal: brain.hunger == 1, snack: brain.happiness == 1, size: size)
                    .position(x: head.x + size * 0.3, y: head.y - size * 0.12)
            }
            if let m = moment {
                momentEffects(m, head: head, size: size, width: w)
            }
        }
    }

    @ViewBuilder
    private func momentEffects(_ m: TomoMoment, head: CGPoint, size: CGFloat, width w: CGFloat) -> some View {
        let e = m.elapsed(at: now)
        let p = m.progress(at: now)
        switch m.kind {
        case .happy:
            hearts(progress: p, head: head, size: size)
        case .medicine(let cured):
            if e < 0.75 {
                effect("tomo-medicine", fallback: Image(systemName: "cross.case.fill").foregroundStyle(.red))
                    .position(x: head.x - size * 0.5 + CGFloat(e / 0.75) * size * 0.3, y: head.y)
            } else if cured {
                sparkles(progress: (e - 0.75) / 0.75, center: head, radius: size * 0.3)
            }
        case .sad:
            effect("tomo-sweat", fallback: Image(systemName: "drop.fill").foregroundStyle(.blue))
                .position(x: head.x + size * 0.18, y: head.y + CGFloat(p) * size * 0.05)
        case .scold:
            if e < 0.4 {
                effect("tomo-scold", fallback: Image(systemName: "bolt.fill").font(.title).foregroundStyle(.yellow))
                    .position(x: head.x, y: head.y - size * 0.15)
            }
        case .evolve:
            if p >= 0.3 { sparkles(progress: p, center: CGPoint(x: head.x, y: head.y + size * 0.1), radius: size * 0.4) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func momentOverlay(width w: CGFloat, height h: CGFloat) -> some View {
        if let m = moment {
            let e = m.elapsed(at: now)
            let p = m.progress(at: now)
            switch m.kind {
            case .evolve where p < 0.3:
                Color.white.opacity(abs(sin(e * 18)) * 0.8)
            case .burst where p < 0.6:
                ZStack {
                    Color.white.opacity(0.9 * (1 - p / 0.6))
                    effect("tomo-burst", fallback: Image(systemName: "sun.max.fill").font(.system(size: 60)).foregroundStyle(.yellow))
                        .scaleEffect(0.5 + p * 3)
                        .opacity(1 - p / 0.6)
                }
            default:
                EmptyView()
            }
        }
    }

    private func hearts(progress p: Double, head: CGPoint, size: CGFloat) -> some View {
        ForEach(0..<3, id: \.self) { i in
            let local = min(1, max(0, p * 1.4 - Double(i) * 0.2))
            effect("tomo-heart", fallback: Image(systemName: "heart.fill").foregroundStyle(.pink))
                .opacity(local > 0 ? 1 - local : 0)
                .position(x: head.x + CGFloat(i - 1) * size * 0.18, y: head.y - CGFloat(local) * size * 0.35)
        }
    }

    private func sparkles(progress p: Double, center: CGPoint, radius: CGFloat) -> some View {
        ForEach(0..<5, id: \.self) { i in
            let angle = Double(i) / 5 * 2 * .pi + p * 4
            effect("tomo-sparkle", fallback: Image(systemName: "sparkle").foregroundStyle(.yellow))
                .opacity(1 - p * 0.5)
                .position(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius * 0.6)
        }
    }

    /// A shared item: your drawing if it exists, otherwise a stand-in.
    private func effect<F: View>(_ name: String, fallback: F) -> some View {
        Group {
            if let art = TomoArt.item(name) {
                Image(art).resizable().scaledToFit().frame(width: 28, height: 28)
            } else {
                fallback
            }
        }
    }
}

/// §4: the thought bubble shown when a meter has one step left: the meal
/// for hunger, the snack for happiness, or both. Uses `tomo-thought` and
/// the whole `tomo-meal-1` / `tomo-snack-1` drawings when they exist.
private struct TomoThoughtBubble: View {
    let meal: Bool
    let snack: Bool
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: d * 0.15) {
                if meal { food("tomo-meal-1", symbol: "fork.knife", color: .orange) }
                if snack { food("tomo-snack-1", symbol: "birthday.cake.fill", color: .pink) }
            }
            .padding(.horizontal, d * 0.35)
            .padding(.vertical, d * 0.25)
            .background {
                if let art = TomoArt.item("tomo-thought") {
                    Image(art).resizable()
                } else {
                    Capsule().fill(Color.white).shadow(color: .black.opacity(0.15), radius: 2)
                }
            }
            // The two little trailing circles that make it a thought.
            if TomoArt.item("tomo-thought") == nil {
                Circle().fill(Color.white).frame(width: d * 0.22, height: d * 0.22)
                    .shadow(color: .black.opacity(0.15), radius: 1)
                    .offset(x: -d * 0.05, y: d * 0.3)
                Circle().fill(Color.white).frame(width: d * 0.13, height: d * 0.13)
                    .shadow(color: .black.opacity(0.15), radius: 1)
                    .offset(x: -d * 0.25, y: d * 0.52)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func food(_ name: String, symbol: String, color: Color) -> some View {
        if let art = TomoArt.item(name) {
            Image(art).resizable().scaledToFit().frame(width: d, height: d)
        } else {
            Image(systemName: symbol).resizable().scaledToFit()
                .foregroundStyle(color).frame(width: d * 0.8, height: d * 0.8)
                .frame(width: d, height: d)
        }
    }

    private var d: CGFloat { size * 0.13 }
}

/// The room the tomomix lives in: a square drawing (`tomo-room`) that fills
/// the whole screen, with the window cut out so the sky behind it shows
/// through. The sky follows the time of day (`tomo-sky-morning`, `-day`,
/// `-evening`, `-night`), and turns to night when the light is off.
struct TomoRoom: View {
    let simNow: Date
    let lightsOn: Bool
    let asleep: Bool

    enum TimeOfDay: String { case morning, day, evening, night }

    static func timeOfDay(_ date: Date, lightsOn: Bool) -> TimeOfDay {
        guard lightsOn else { return .night }
        switch Calendar.current.component(.hour, from: date) {
        case 6..<10: return .morning
        case 10..<17: return .day
        case 17..<20: return .evening
        default: return .night
        }
    }

    var body: some View {
        let time = Self.timeOfDay(simNow, lightsOn: lightsOn)
        ZStack {
            if let sky = TomoArt.item("tomo-sky-\(time.rawValue)") {
                Image(sky).resizable().scaledToFill()
            } else {
                LinearGradient(colors: Self.skyColors(time), startPoint: .top, endPoint: .bottom)
            }
            if let room = TomoArt.item("tomo-room") {
                Image(room).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
    }

    /// Stand-in skies until the drawings exist.
    private static func skyColors(_ time: TimeOfDay) -> [Color] {
        switch time {
        case .morning: return [Color(red: 1.0, green: 0.85, blue: 0.66), Color(red: 0.75, green: 0.88, blue: 0.97)]
        case .day: return [Color(red: 0.55, green: 0.80, blue: 0.97), Color(red: 0.78, green: 0.91, blue: 0.99)]
        case .evening: return [Color(red: 0.98, green: 0.62, blue: 0.48), Color(red: 0.55, green: 0.42, blue: 0.70)]
        case .night: return [Color(red: 0.08, green: 0.11, blue: 0.27), Color(red: 0.18, green: 0.20, blue: 0.42)]
        }
    }
}

/// §10: up to 8 poops, small ones turning big after the 4th. `newestDrop`
/// (0-1) lifts the newest one while it falls in.
struct PoopPile: View {
    let count: Int
    var newestDrop: Double = 0

    var body: some View {
        let big = max(0, count - 4)
        let small = min(count, 4) - big
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<max(0, small), id: \.self) { i in
                piece(big: false).offset(y: (big == 0 && i == small - 1) ? -CGFloat(newestDrop) * 40 : 0)
            }
            ForEach(0..<big, id: \.self) { i in
                piece(big: true).offset(y: i == big - 1 ? -CGFloat(newestDrop) * 40 : 0)
            }
        }
    }

    @ViewBuilder
    private func piece(big: Bool) -> some View {
        let side: CGFloat = big ? 20 : 12
        if let art = TomoArt.item(big ? "tomo-poop-big" : "tomo-poop-small") {
            Image(art).resizable().scaledToFit().frame(width: side, height: side)
        } else {
            Circle().fill(.brown).frame(width: side, height: side)
        }
    }
}

// MARK: - Birth and ending scenes (Animations.md §5)

struct NightSky: View {
    var now: Date = Date()

    var body: some View {
        let art = TomoArt.item("tomo-bg-night-sky").flatMap { UIImage(named: $0) }
        return Canvas { context, size in
            if let art {
                context.draw(Image(uiImage: art), in: CGRect(origin: .zero, size: size))
            } else {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.2), Color(red: 0.15, green: 0.1, blue: 0.3)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            var rng = TomoRandom(state: 42)
            let t = now.timeIntervalSinceReferenceDate
            for i in 0..<40 {
                let x = rng.unit() * size.width, y = rng.unit() * size.height
                let r = 0.6 + rng.unit() * 1.2
                let twinkle = 0.65 + 0.35 * sin(t * (1 + Double(i % 5) * 0.4) + Double(i))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity((0.4 + rng.unit() * 0.5) * twinkle)))
            }
        }
    }
}

private struct Ground: View {
    var body: some View {
        VStack {
            Spacer()
            Group {
                if let art = TomoArt.item("tomo-ground") {
                    Image(art).resizable()
                } else {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.22), Color(red: 0.06, green: 0.1, blue: 0.14)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(height: 34)
        }
    }
}

/// §3 birth: sky, shooting star, close-up fall (the intro, skippable), then
/// the fallen star pulsing faster and faster until it's born.
struct TomoBirthScene: View {
    let bornAt: Date
    let simNow: Date
    let now: Date
    let intro: TomoMoment?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                NightSky(now: now)
                if let m = intro {
                    let e = m.elapsed(at: now)
                    if e >= 1.5 && e < 3.5 {
                        let p = (e - 1.5) / 2
                        star(named: "tomo-shooting-star", trail: true, size: 22)
                            .position(x: -w * 0.1 + w * 1.2 * p, y: h * 0.18 + h * 0.12 * p)
                    } else if e >= 3.5 {
                        let p = min(1, (e - 3.5) / 1.5)
                        Ground()
                        star(named: "tomo-star-falling", trail: true, size: 30 + 10 * p)
                            .rotationEffect(.degrees(60))
                            .position(x: w * 0.5, y: -h * 0.1 + (h * 0.78) * p * p)
                    }
                } else {
                    Ground()
                    PulsingStar(timeLeft: bornAt.timeIntervalSince(simNow))
                        .position(x: w / 2, y: h - 34)
                }
            }
        }
    }

    @ViewBuilder
    private func star(named name: String, trail: Bool, size: CGFloat) -> some View {
        if let art = TomoArt.item(name) {
            Image(art).resizable().scaledToFit().frame(width: size * 3, height: size * 3)
        } else {
            HStack(spacing: -4) {
                if trail {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, .yellow.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: size * 2.2, height: size * 0.25)
                }
                Image(systemName: "star.fill").font(.system(size: size)).foregroundStyle(.yellow)
                    .shadow(color: .yellow, radius: 6)
            }
            .offset(x: trail ? -size * 1.1 : 0)
        }
    }
}

/// The fallen star: pulses slowly at first, faster as birth nears.
private struct PulsingStar: View {
    let timeLeft: TimeInterval

    var body: some View {
        let total = TomoRules.starPulseSeconds
        let elapsed = max(0, total - max(0, timeLeft))
        // Pulse rate rises from 0.5 to 4 per second; integrate for phase.
        let f0 = 0.5, f1 = 4.0
        let phase = 2 * Double.pi * (f0 * elapsed + (f1 - f0) * elapsed * elapsed / (2 * total))
        let glow = (sin(phase) + 1) / 2
        Group {
            if let art = TomoArt.item("tomo-star-fallen") {
                Image(art).resizable().scaledToFit().frame(width: 60, height: 60)
            } else {
                Image(systemName: "star.fill").font(.system(size: 34)).foregroundStyle(.yellow)
            }
        }
        .shadow(color: .yellow, radius: 4 + 14 * glow)
        .scaleEffect(0.85 + 0.25 * glow, anchor: .bottom)
        .offset(y: -16)
    }
}

/// §12 ending: the tomomix fades as the night falls and its star appears.
struct TomoEndingScene: View {
    let character: TomoCharacter
    let ageYears: Int
    let now: Date
    /// 0-1 while the transition plays; nil once it has settled.
    let transition: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let size = h * 0.86
            let p = transition ?? 1
            let twinkle = 1 + 0.08 * sin(now.timeIntervalSinceReferenceDate * 2)
            ZStack {
                Color(.systemBackground)
                NightSky(now: now).opacity(p)
                TomoSprite(character: character, pose: .idle)
                    .frame(width: size, height: size)
                    .opacity(1 - 0.75 * p)
                    .blur(radius: CGFloat(p))
                    .offset(y: -h * 0.12 * CGFloat(p))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Group {
                    if let art = TomoArt.item("tomo-star-fixed") {
                        Image(art).resizable().scaledToFit().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "star.fill").font(.system(size: 30)).foregroundStyle(.yellow)
                    }
                }
                .scaleEffect(twinkle)
                .opacity(max(0, (p - 0.5) * 2))
                .offset(y: -h * 0.12)
                if transition == nil {
                    VStack {
                        Spacer()
                        Text("Age \(ageYears)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}
