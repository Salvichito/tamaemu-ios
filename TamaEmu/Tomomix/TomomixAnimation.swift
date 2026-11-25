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

    private static var boxes: [String: CGRect] = [:]

    /// Where the drawing's ink actually is, as fractions of its square
    /// (0-1), measured once from a small render and remembered.
    static func inkBounds(_ name: String) -> CGRect? {
        if let known = boxes[name] { return known }
        guard let image = UIImage(named: name) else { return nil }
        let n = 64
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let found: CGRect? = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: 0, y: 0, width: n, height: n))
            UIGraphicsPopContext()
            var minX = n, minY = n, maxX = -1, maxY = -1
            for y in 0..<n {
                for x in 0..<n where buffer[(y * n + x) * 4 + 3] > 40 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            let f = CGFloat(n)
            return CGRect(x: CGFloat(minX) / f, y: CGFloat(minY) / f,
                          width: CGFloat(maxX - minX + 1) / f, height: CGFloat(maxY - minY + 1) / f)
        }
        if let found { boxes[name] = found }
        return found
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
        /// Scolded for no reason: sad, with the confused mark.
        case confused
        case burst
        case depart(TomoCharacter)
        /// Tapped: a surprised little hop (happy face).
        case poke
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
        case .happy, .sad, .clean, .burst: return 1.5
        case .scold: return 2.3
        case .confused: return 2.0
        case .medicine: return TomoFrog.duration
        case .poop: return PoopPile.flightDuration
        case .poke: return 0.6
        case .evolve, .depart: return 3
        case .birthIntro: return TomoRules.birthIntroSeconds
        }
    }

    func elapsed(at date: Date) -> TimeInterval { max(0, date.timeIntervalSince(start)) }
    func progress(at date: Date) -> Double { min(1, elapsed(at: date) / duration) }
    func isOver(at date: Date) -> Bool { date.timeIntervalSince(start) >= duration }

    var isBirthIntro: Bool { if case .birthIntro = kind { return true } else { return false } }

    /// How white the whole screen is (0-1). Just born: it starts white and
    /// fades into the room. Evolving: it hops, explodes into white, and the
    /// new character appears as the white fades.
    func whiteout(at date: Date) -> Double {
        let p = progress(at: date)
        switch kind {
        case .burst: return max(0, 1 - p / 0.6)
        case .evolve: return TomoMoment.evolveWhite(p)
        default: return 0
        }
    }

    /// Evolving (3 s): hop up (0-0.2), the explosion grows and the screen
    /// whitens (0.2-0.5), the new character is under the white at 0.5, and
    /// the white fades away (0.5-0.8).
    static func evolveWhite(_ p: Double) -> Double {
        p < 0.2 ? 0 : p < 0.5 ? (p - 0.2) / 0.3 : max(0, 1 - (p - 0.5) / 0.3)
    }
}

/// The explosion (`tomo-evolution`, white rays) used at birth and when
/// evolving. `q` 0-1: it grows from small to past the screen, turning a little.
struct TomoExplosion: View {
    let q: Double
    let side: CGFloat

    var body: some View {
        Group {
            if let art = TomoArt.item("tomo-evolution") {
                Image(art).resizable().scaledToFit()
            } else {
                Image(systemName: "sun.max.fill").resizable().scaledToFit().foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(0.25 + 1.6 * q)
        .rotationEffect(.degrees(40 * q))
        .shadow(color: .white, radius: 8)
        .allowsHitTesting(false)
    }
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

/// Prototype tools' preview: which character and which drawing to show
/// instead of the live ones (nil = live).
struct TomoPreview: Equatable {
    var character: TomoCharacter?
    var drawing: Drawing?
    /// An effect played over and over, to check its art.
    var effect: Effect?

    enum Effect: String, CaseIterable {
        case hearts = "Hearts (happy)"
        case scold = "Scold"
        case confused = "Confused (scolded for nothing)"
        case needy = "Spiral (needs care)"
        case sick = "Ball (sick)"
        case bubble = "Thought bubble"
        case zzz = "Asleep (ZZZ, blanket)"
        case meal = "Eating a meal"
        case snack = "Eating a snack"
        case poopSmall = "Poop (small)"
        case poopBig = "Poop (big)"
        case clean = "Cleaning"
        case medicine = "Medicine + sparkles"
        case evolve = "Evolving"

        /// The animation to loop for this effect, restarted every time it
        /// ends (with a short pause), or nil for the ones that stay on.
        func moment(now: Date, character: TomoCharacter) -> TomoMoment? {
            let kind: TomoMoment.Kind
            switch self {
            case .hearts: kind = .happy
            case .scold: kind = .scold
            case .confused: kind = .confused
            case .meal: kind = .eat(snack: false, bites: 3)
            case .snack: kind = .eat(snack: true, bites: 2)
            case .clean: kind = .clean(poop: 4)
            case .medicine: kind = .medicine(cured: true)
            case .evolve: kind = .evolve(from: character, to: character)
            default: return nil
            }
            let loop = TomoMoment(kind).duration + 0.6
            let t = now.timeIntervalSinceReferenceDate
            return TomoMoment(kind, at: now.addingTimeInterval(-t.truncatingRemainder(dividingBy: loop)))
        }

        /// The mark that stays on for this effect (TomoStage.forceMark).
        var mark: String? {
            switch self {
            case .needy: return "needy"
            case .sick: return "sick"
            case .bubble: return "bubble"
            case .zzz: return "zzz"
            case .poopSmall: return "poop-small"
            case .poopBig, .clean: return "poop-big"
            default: return nil
            }
        }
    }

    struct Drawing: Equatable {
        let name: String
        let pose: TomoPose
        let frame: Int
    }

    /// The 9 drawings every character has, in the art guide's order.
    static let drawings: [Drawing] = [
        Drawing(name: "idle-1", pose: .idle, frame: 1),
        Drawing(name: "blink", pose: .blink, frame: 1),
        Drawing(name: "eat-1", pose: .eat, frame: 1),
        Drawing(name: "eat-2", pose: .eat, frame: 2),
        Drawing(name: "refuse", pose: .refuse, frame: 1),
        Drawing(name: "happy", pose: .happy, frame: 1),
        Drawing(name: "sick", pose: .sick, frame: 1),
        Drawing(name: "look", pose: .look, frame: 1),
        Drawing(name: "look-right", pose: .lookRight, frame: 1),
    ]
}

/// The tomomix in its room: base behavior (wandering, blinking, sleeping,
/// sick, calling, pouting) with the current moment layered on top.
struct TomoStage: View {
    let brain: TomoBrain
    let moment: TomoMoment?
    let now: Date
    let caption: String?
    /// Prototype tools: draw another character and/or hold one drawing,
    /// without touching the real tomomix.
    var preview: TomoPreview = TomoPreview()
    /// Prototype tools' placement check: always show this mark
    /// ("needy", "sick" or "bubble").
    var forceMark: String? = nil
    /// Out on the grass: the poop stays behind in the room.
    var outdoors = false
    /// Playing Follow Me: it stands in the middle and shows the directions.
    var game: TomomixViewModel.GameState? = nil

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

                if let m = moment, case .eat(let snack, let bites) = m.kind {
                    // Twice the old size, standing on the floor on its left.
                    foodProp(snack: snack, bites: bites, moment: m)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .position(x: w / 2 - size * 0.5, y: h - size * 0.23)
                }

                // A new poop shoots out from behind it (drawn under it
                // until it's clear, then with the rest of the pile).
                if !outdoors, let m = moment, case .poop = m.kind {
                    poopLayer(width: w, height: h, behindOnly: true)
                }

                TomoSprite(character: look.character, pose: look.pose, frame: look.frame, mirrored: look.mirrored)
                    .frame(width: size, height: size)
                    .colorMultiply(look.silhouette ? .black : .white)
                    // Asleep: it breathes, slowly growing and shrinking a little.
                    .scaleEffect(look.scale * (look.pose == .sleep ? breath : 1), anchor: .bottom)
                    .opacity(look.opacity)
                    .position(x: w / 2 + look.x, y: h - size / 2 + look.y)

                if look.pose == .sleep {
                    blanket(look: look, size: size, width: w, height: h)
                }

                effects(head: head, size: size, width: w, height: h)

                // In front of everything (they're nearer the player), under
                // the swoosh. Poop stays in the room when it goes outside.
                if !outdoors {
                    poopLayer(width: w, height: h)
                }

                momentOverlay(width: w, height: h)

                if let caption {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.tomo(.footnote))
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
        var l = liveLook(width: w, size: size)
        if let c = preview.character { l.character = c }
        if let p = preview.drawing {
            // Held still, center stage, so drawings can be compared.
            l.pose = p.pose
            l.frame = p.frame
            l.x = 0; l.y = 0
            l.mirrored = false; l.scale = 1; l.opacity = 1; l.silhouette = false
        }
        return l
    }

    private func liveLook(width w: CGFloat, size: CGFloat) -> TomoLook {
        // Old tomomixis move a little slower (Animations.md §4).
        let t = now.timeIntervalSinceReferenceDate * (brain.isOld ? 0.7 : 1)
        var l = TomoLook(character: brain.character)

        if brain.asleep || forceMark == "zzz" {
            l.pose = .sleep
        } else if brain.sick {
            l.pose = .sick
        } else if brain.needsCare {
            l.pose = .call
        } else {
            l.frame = Int(t * 2).isMultiple(of: 2) ? 1 : 2
            if t.truncatingRemainder(dividingBy: 3.7) < 0.15 { l.pose = .blink; l.frame = 1 }
        }

        // Sick: it stays still in the middle with its sick face (no
        // blinking, no hopping) until it's cured.
        // Wander around while awake, the classic way: no sliding, it hops
        // one step at a time, a couple of times a second, for a retro feel.
        // It isn't flipped when walking right: some characters aren't
        // symmetric (curly hair).
        if brain.sick, !brain.asleep {
            // Sick: still in the middle, sad, with a sudden shiver now and
            // then (goosebumps): a few quick jolts left and right.
            let period = 2.2
            let n = Int((t / period).rounded(.down))
            let into = t - Double(n) * period
            let start = Double(Self.shuffle(n &* 977 &+ 3) % 100) / 100 * 1.2
            if into >= start, into < start + 0.36 {
                l.x = (Int((into - start) / 0.06) % 2 == 0 ? 1 : -1) * size * 0.025
            }
        }
        if !brain.asleep, !brain.sick {
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
            case nil:
                // Walking: it looks the way it's going (its look / look-right
                // drawings), now and then glancing back at the player.
                if calm, walk.heading != 0 {
                    let step = Int((t / 0.5).rounded(.down))
                    let glance = Self.shuffle(step &* 131 &+ 7) % 4 == 0
                    if !glance { l.pose = walk.heading < 0 ? .look : .lookRight; l.frame = 1 }
                }
            }
        }

        if let game {
            // Follow Me: still in the middle, looking the way that's lit,
            // happy or sad at the result.
            l.x = 0
            l.y = 0
            l.mirrored = false
            l.frame = 1
            if game.intro {
                // "Let's play!": happy little hops in steps, with the tune.
                l.pose = .happy
                if Int(now.timeIntervalSinceReferenceDate * 4) % 2 == 0 { l.y = -size * 0.1 }
                return l
            }
            switch game.step {
            case .result(let score, _) where score == TomoRules.gameRounds:
                // A perfect game: happy hops to celebrate.
                l.pose = .happy
                if Int(now.timeIntervalSinceReferenceDate * 4) % 2 == 0 { l.y = -size * 0.1 }
            case .result(_, let reward) where reward > 0:
                // An okay game: just a smile.
                l.pose = .happy
            case .result: l.pose = .sad
            default: l.pose = game.lit == nil ? .idle : game.lit == true ? .lookRight : .look
            }
            return l
        }
        guard let m = moment else { return l }
        let e = m.elapsed(at: now)
        let p = m.progress(at: now)
        if case .clean = m.kind {
            // Cleaning: it carries on just as before while the swoosh passes.
            return l
        }
        if case .poke = m.kind {
            // Right where it stands: up, half way, landed, in steps.
            l.pose = .happy
            l.frame = 1
            l.y -= e < 0.15 ? size * 0.08 : e < 0.3 ? size * 0.035 : 0
            return l
        }
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
            // "Sana sana, culito de rana": sick while the frog comes, grossed
            // out by its toot, then (if that did it) hopping for joy.
            if e < TomoFrog.toot { l.pose = .sick }
            else if e < TomoFrog.toot + 0.7 {
                l.pose = .refuse
                l.x = sin(e * 30) * size * 0.02
            } else if cured {
                l.pose = .happy
                l.y = -abs(sin((e - TomoFrog.toot - 0.7) / 1.2 * .pi * 2)) * size * 0.08
            } else { l.pose = .sick }
        case .clean, .poop:
            l.pose = .idle
        case .scold:
            // Upset (angry, shaking), then sad (crying, a smaller shake),
            // then it accepts it: happy, with a hop.
            if e < 0.7 {
                l.pose = .refuse
                l.x = (Int(e / 0.06) % 2 == 0 ? 1 : -1) * size * 0.025
            } else if e < 1.5 {
                l.pose = .sad
                l.x = (Int(e / 0.09) % 2 == 0 ? 1 : -1) * size * 0.012
            } else {
                l.pose = .happy
                if e < 1.85 { l.y = -size * 0.1 }
            }
        case .evolve(let from, let to):
            if p < 0.5 {
                // A little hop up, and it stays up while it bursts.
                l.character = from
                l.pose = .happy
                let up = min(1, p / 0.2)
                l.y = -size * 0.1 * CGFloat(1 - (1 - up) * (1 - up))
            } else {
                // Under the white it's already the new one, happy.
                l.character = to
                l.pose = .happy
            }
        case .burst:
            l.pose = .happy
        case .confused:
            l.pose = .sad
        case .birthIntro, .depart, .poke:
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
    static func wander(at t: TimeInterval, slow: Bool, jumpChance: Double) -> (x: CGFloat, depth: Int, jump: JumpBeat?, heading: Int) {
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
        // Which way it's stepping sideways right now: -1 left, 1 right, 0 not.
        let heading = into < abs(distance) ? (distance < 0 ? -1 : 1) : 0

        // A jump takes two beats of the wait after arriving: up, then a
        // smile back on the ground.
        let wait = stepsPerLeg - travel
        guard jumpChance > 0, wait >= 2 else { return (x, depth, nil, heading) }
        let roll = shuffle(leg &* 7919 &+ 1)
        guard Double(roll % 1000) / 1000 < jumpChance else { return (x, depth, nil, heading) }
        let start = travel + Int((roll / 1000) % UInt64(wait - 1))
        switch into - start {
        case 0: return (x, depth, .up, heading)
        case 1: return (x, depth, .landed, heading)
        default: return (x, depth, nil, heading)
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

    private func poopLayer(width w: CGFloat, height h: CGFloat, behindOnly: Bool = false) -> some View {
        var count = forceMark == "poop-small" ? 3 : forceMark == "poop-big" ? 6 : brain.poop
        var grabX: CGFloat?
        var flight: Double?
        if let m = moment {
            switch m.kind {
            case .clean(let n):
                count = n
                grabX = Self.swooshX(progress: m.progress(at: now), width: w, height: h)
            case .poop: flight = m.elapsed(at: now)
            default: break
            }
        }
        // Its bottom, where the tomomix stands center stage (size = h * 0.86).
        let size = h * 0.86
        return PoopPile(count: count, flight: flight,
                        launch: CGPoint(x: w / 2 + size * 0.05, y: h - size * 0.38),
                        behindOnly: behindOnly, now: now, side: h * 0.52,
                        width: w, height: h, grabX: grabX)
    }

    /// The cleaning swoosh's center across the stage at `progress` (0-1):
    /// in from the left edge, out past the right one, easing in and out.
    static func swooshX(progress p: Double, width w: CGFloat, height h: CGFloat) -> CGFloat {
        let q = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        let band = swooshHeight(h) * 481 / 1075
        let from = -w * 0.15 - band / 2, to = w * 1.15 + band / 2
        return from + (to - from) * CGFloat(q)
    }

    /// Tall enough to cover the whole screen, top to bottom.
    /// The game screen is 1/0.64 of the stage tall; a little extra so the
    /// band's soft ends never show.
    static func swooshHeight(_ h: CGFloat) -> CGFloat { h / 0.64 * 1.08 }

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
            if brain.asleep || forceMark == "zzz", moment == nil, TomoArt.item("tomo-zzz-1") != nil {
                // The letters of tomo-zzz appear one after another, stay a
                // moment, then all go and it starts again (3 s).
                let e = t.truncatingRemainder(dividingBy: 3)
                ZStack {
                    ForEach(1...3, id: \.self) { i in
                        if e >= Double(i - 1) * 0.6, e < 2.4, let art = TomoArt.item("tomo-zzz-\(i)") {
                            Image(art).resizable().scaledToFit()
                        }
                    }
                }
                .frame(width: size * 0.5, height: size * 0.5)
                .position(x: head.x + size * 0.32, y: head.y - size * 0.2)
            } else if brain.asleep, moment == nil {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    effect("tomo-zzz", fallback: Text("Z").font(.system(size: 12 + CGFloat(i) * 4, weight: .bold)))
                        .opacity(1 - phase)
                        .position(x: head.x + size * 0.15 + CGFloat(phase) * size * 0.15, y: head.y - CGFloat(phase) * size * 0.25)
                }
            }
            if brain.sick || (forceMark ?? Self.debugMark) == "sick", let art = TomoArt.item("tomo-sick-\(Int(t / 0.22) % 3 + 1)") {
                // The scribble ball churns (3 drawings) beside its head, top right.
                Image(art).resizable().scaledToFit()
                    .frame(width: markSide(size), height: markSide(size))
                    .position(besideHead(head, size: size))
            } else if brain.sick {
                effect("tomo-skull", fallback: Text("☠︎").font(.title2))
                    .position(x: w - 22, y: 22)
            }
            // Misbehaving only lights the attention icon: no mark, no change.
            if (forceMark ?? Self.debugMark) == "needy" || (!brain.asleep && brain.needsCare && !brain.sick && moment == nil && game == nil),
                      let art = TomoArt.item("tomo-needy-\(Int(t / 0.22) % 3 + 1)") {
                // Needs care: the dizzy spiral turns beside its head, top right.
                Image(art).resizable().scaledToFit()
                    .frame(width: markSide(size), height: markSide(size))
                    .position(besideHead(head, size: size))
            } else if !brain.asleep, brain.needsCare, !brain.sick, moment == nil, game == nil {
                effect("tomo-call", fallback: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red))
                    .position(x: head.x + size * 0.2, y: head.y - size * 0.05)
            } else if (forceMark ?? Self.debugMark) == "bubble" || (!brain.asleep && !brain.sick && moment == nil && game == nil &&
                      (brain.hunger == 1 || brain.happiness == 1)) {
                // §4: one step left on a meter, so it thinks about what
                // it'll soon want, before it starts calling.
                TomoThoughtBubble(meal: brain.hunger == 1, snack: brain.happiness == 1, size: size, now: now)
                    .position(bubbleCenter(head, size: size, width: w, height: h))
            }
            if let m = moment {
                momentEffects(m, head: head, size: size, width: w)
            }
        }
    }

    /// Sleeping breath: about one slow breath every 3.2 s, ±2.5% in size.
    private var breath: CGFloat {
        1 + 0.025 * CGFloat(sin(now.timeIntervalSinceReferenceDate * 2 * .pi / 3.2))
    }

    /// How far below the top of each character's drawing the blanket's
    /// white edge sits, from the mockups (in their pixels: the blanket's
    /// visible width there is 1092 px, and a character's square ≈ 1025 px).
    static let blanketEdge: [TomoCharacter: CGFloat] = [
        .baby: 169, .childGood: 159, .childBad: 141,
        .teenExcellent: 315, .teenGood: 351, .teenBad: 393,
        .adult1A: 612, .adult1B: 494, .adult1C: 486, .adult1D: 372,
        .adult2A: 465, .adult2B: 390, .adult2C: 528, .adult2D: 468,
        .adult3A: 492, .adult3B: 560, .adult3C: 304, .adult3D: 392,
    ]

    /// The blanket (`tomo-blanket`, a 596 square whose white edge starts at
    /// y = 185.5) over a sleeping tomomix: the same size for everyone,
    /// centered on the character, its edge at that character's own height.
    @ViewBuilder
    private func blanket(look: TomoLook, size: CGFloat, width w: CGFloat, height h: CGFloat) -> some View {
        if let art = TomoArt.item("tomo-blanket") {
            let box = inkBox()
            let side = size * 1.163
            let top = h - size + look.y + size * box.minY                // the drawing's real top
            let edge = top + size * (Self.blanketEdge[look.character] ?? 300) / 1025
            Image(art).resizable().scaledToFit()
                .frame(width: side, height: side)
                .position(x: w / 2 + look.x + size * (box.midX - 0.5),
                          y: edge - side * 185.5 / 596 + side / 2)
        }
    }

    /// Where this character's drawing really is inside its square, from
    /// its idle drawing (the placeholder's circle until there's art).
    private var shownCharacter: TomoCharacter { preview.character ?? brain.character }

    #if DEBUG
    /// Debug only: TOMO_DEBUG_MARKS=needy|sick|bubble shows that mark all
    /// the time, to check its placement on every character.
    static let debugMark = ProcessInfo.processInfo.environment["TOMO_DEBUG_MARKS"]
    #else
    static let debugMark: String? = nil
    #endif

    private func inkBox() -> CGRect {
        let k = shownCharacter.placeholderScale
        let guess = CGRect(x: 0.5 - k / 2, y: TomoArtboard.baseline - k, width: k, height: k)
        return TomoArt.imageName(shownCharacter, .idle, 1).flatMap { TomoArt.inkBounds($0) } ?? guess
    }

    /// The needy spiral and sick ball float just off the top right of its
    /// head, manga style, overlapping the corner a little. Placed from the
    /// drawing's real outline, so it hugs small and big characters alike.
    private func besideHead(_ head: CGPoint, size: CGFloat) -> CGPoint {
        let c = headCorner(head, size: size)
        // Hand-tuned nudges, in units of the 596 room drawing (the game
        // screen is 596 wide), so they look the same on every screen.
        let nudge = Self.markNudges[shownCharacter] ?? .zero
        let screen = size / (0.64 * 0.86)          // the stage is 64% of the screen; the sprite 86% of that
        // Clear of the drawing: up and to the right of its top-right corner,
        // so the spiral's lower-left edge only just reaches the corner.
        return CGPoint(x: c.x + size * 0.1 + screen * nudge.x / 596,
                       y: c.y - size * 0.05 + screen * nudge.y / 596)
    }

    /// Per-character fine-tuning for the spiral and the ball (+x right,
    /// +y down, in 596-drawing units). Characters not listed use the
    /// automatic spot.
    static let markNudges: [TomoCharacter: CGPoint] = [
        .adult1A: CGPoint(x: -10, y: 10),
        .adult1C: CGPoint(x: 0, y: 10),
        .adult2C: CGPoint(x: -20, y: 0),
        .adult2D: CGPoint(x: 0, y: 10),
        .adult3D: CGPoint(x: -20, y: 0),
    ]

    /// The same for the thought bubble.
    static let bubbleNudges: [TomoCharacter: CGPoint] = [
        .adult1A: CGPoint(x: -10, y: 10),
    ]

    /// The top-right corner of the drawing's real outline, on the stage.
    /// The spiral, the ball and the thought bubble all hang off this point.
    private func headCorner(_ head: CGPoint, size: CGFloat) -> CGPoint {
        let box = inkBox()
        // `head` is set from the sprite square; recover that square's top.
        let top = head.y - size * (0.8 - shownCharacter.placeholderScale)
        return CGPoint(x: head.x + size * (box.maxX - 0.5), y: top + size * box.minY)
    }

    /// The left side of its face, on the stage: where the frog aims.
    private func faceLeft(_ head: CGPoint, size: CGFloat) -> CGPoint {
        let box = inkBox()
        let top = head.y - size * (0.8 - shownCharacter.placeholderScale)
        return CGPoint(x: head.x + size * (box.minX - 0.5), y: top + size * (box.minY + box.height * 0.4))
    }

    /// Where the thought bubble goes: its trailing puffs just off the
    /// drawing's top-right corner, the cloud up and to the right, kept on
    /// screen (not past the right edge, not into the top row of icons).
    private func bubbleCenter(_ head: CGPoint, size: CGFloat, width w: CGFloat, height h: CGFloat) -> CGPoint {
        let c = headCorner(head, size: size)
        let side = TomoThoughtBubble.side(for: size)
        // The tail's tip is at (23, 248) of the 256 drawing.
        let tail = CGPoint(x: c.x + size * 0.04, y: c.y + size * 0.1)
        let nudge = Self.bubbleNudges[shownCharacter] ?? .zero
        let screen = size / (0.64 * 0.86)
        var x = tail.x + side * (0.5 - 23.0 / 256) + screen * nudge.x / 596
        var y = tail.y - side * (248.0 / 256 - 0.5) + screen * nudge.y / 596
        x = min(x, w * 1.1 - side / 2)
        y = max(y, side / 2 - h * 0.12)
        return CGPoint(x: x, y: y)
    }

    /// The drawing's square; the spiral or ball itself is about half of it,
    /// so roughly a tenth of the screen across, for every character.
    private func markSide(_ size: CGFloat) -> CGFloat {
        size * 0.4
    }

    @ViewBuilder
    private func momentEffects(_ m: TomoMoment, head: CGPoint, size: CGFloat, width w: CGFloat) -> some View {
        let e = m.elapsed(at: now)
        let p = m.progress(at: now)
        switch m.kind {
        case .happy:
            hearts(progress: p, head: head, size: size)
        case .medicine(let cured):
            TomoFrog(elapsed: e, face: faceLeft(head, size: size), stageWidth: w, petSize: size, outdoors: outdoors)
            if cured, e >= TomoFrog.toot + 0.7, e < TomoFrog.toot + 2.3 {
                sparkles(progress: (e - TomoFrog.toot - 0.7) / 1.6, head: head, size: size)
            }
        case .sad:
            effect("tomo-sweat", fallback: Image(systemName: "drop.fill").foregroundStyle(.blue))
                .position(x: head.x + size * 0.18, y: head.y + CGFloat(p) * size * 0.05)
        case .confused:
            // The confused squiggle turns (3 drawings) where the spiral goes.
            let frames = ["tomo-confused-1", "tomo-confused-2", "tomo-confused-2-1"]
            if let art = TomoArt.item(frames[Int(now.timeIntervalSinceReferenceDate / 0.22) % 3]) {
                Image(art).resizable().scaledToFit()
                    .frame(width: markSide(size), height: markSide(size))
                    .position(besideHead(head, size: size))
            }
        case .evolve:
            if p >= 0.15, p < 0.55 {
                // From the middle of its actual drawing.
                let box = inkBox()
                let top = head.y - size * (0.8 - shownCharacter.placeholderScale)
                TomoExplosion(q: (p - 0.15) / 0.4, side: size * 0.9)
                    .position(x: head.x + size * (box.midX - 0.5), y: top + size * box.midY)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func momentOverlay(width w: CGFloat, height h: CGFloat) -> some View {
        if let m = moment {
            let p = m.progress(at: now)
            switch m.kind {
            case .clean:
                // The wipe (`tomo-swoosh`): a soft band of stars sweeping across.
                let x = Self.swooshX(progress: p, width: w, height: h)
                let sh = Self.swooshHeight(h)
                ZStack {
                    if let art = TomoArt.item("tomo-swoosh") {
                        Image(art).resizable()
                    } else {
                        LinearGradient(colors: [.clear, .white.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
                    }
                    // Each sparkle shines on its own: growing and shrinking
                    // around its own middle, at its own uneven pace.
                    let t = now.timeIntervalSinceReferenceDate
                    ForEach(1...8, id: \.self) { i in
                        if let name = TomoArt.item("tomo-swoosh-sparkle-\(i)") {
                            let box = TomoArt.inkBounds(name) ?? CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
                            let speed = 5.0 + Double((i * 7) % 5) * 1.6
                            let shine = abs(sin(t * speed + Double(i) * 1.7)) * (0.75 + 0.25 * sin(t * 2.3 + Double(i)))
                            Image(name).resizable()
                                .scaleEffect(0.35 + 0.75 * shine, anchor: UnitPoint(x: box.midX, y: box.midY))
                        }
                    }
                }
                .frame(width: sh * 481 / 1075, height: sh)
                // Centered on the whole game screen (its middle is 0.576 of
                // the stage height down, since the stage starts 13% down).
                .position(x: x, y: h * (0.5 - 0.1316) / 0.64)
                .allowsHitTesting(false)
            default:
                EmptyView()
            }
        }
    }

    private func hearts(progress p: Double, head: CGPoint, size: CGFloat) -> some View {
        ForEach(0..<3, id: \.self) { i in
            let local = min(1, max(0, p * 1.4 - Double(i) * 0.2))
            Group {
                if let art = TomoArt.item("tomo-heart") {
                    Image(art).resizable().scaledToFit().frame(width: size * 0.24, height: size * 0.24)
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
            }
                .opacity(local > 0 ? 1 - local : 0)
                .position(x: head.x + CGFloat(i - 1) * size * 0.18, y: head.y - CGFloat(local) * size * 0.35)
        }
    }

    /// Cured: sparkles scattered over the tomomix's real shape, each one
    /// popping in, growing and shrinking and fading out at its own uneven
    /// pace. Uses `tomo-sparkle` once drawn, until then the Tomomix star.
    private func sparkles(progress p: Double, head: CGPoint, size: CGFloat) -> some View {
        let box = inkBox()
        let top = head.y - size * (0.8 - shownCharacter.placeholderScale)
        let art = TomoArt.item("tomo-sparkle") ?? TomoArt.item("tomo-star-fallen")
        let t = now.timeIntervalSinceReferenceDate
        let fade = min(1, max(0, p < 0.2 ? p / 0.2 : (1 - p) / 0.3))
        return ForEach(0..<9, id: \.self) { i in
            // A fixed, random-looking spot on (and a little around) its outline.
            let rx = Double(Self.shuffle(i &* 37 &+ 11) % 1000) / 1000
            let ry = Double(Self.shuffle(i &* 53 &+ 29) % 1000) / 1000
            let x = head.x + size * (box.minX - 0.05 + (box.width + 0.1) * rx - 0.5)
            let y = top + size * (box.minY - 0.05 + (box.height + 0.05) * ry)
            // Each twinkles on its own beat: in, big-small, out.
            let speed = 4.0 + Double(i % 4) * 1.7
            let shine = max(0, sin(t * speed + Double(i) * 2.3))
            let s = size * (0.06 + 0.07 * Double(Self.shuffle(i &* 71) % 100) / 100)
            Group {
                if let art {
                    Image(art).resizable().scaledToFit()
                } else {
                    Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(.yellow)
                }
            }
            .frame(width: s, height: s * 1.25)
            .scaleEffect(0.3 + 0.9 * shine)
            .opacity(shine * fade)
            .position(x: x, y: y)
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
    /// Redraws with the stage, so the blink between foods keeps time.
    var now = Date()

    var body: some View {
        if let art = TomoArt.item("tomo-thought") {
            // The drawing is a 256 square: the cloud's middle is at
            // (129, 115) and its trailing puffs point down-left, to the head.
            let side = Self.side(for: size)
            ZStack {
                Image(art).resizable().frame(width: side, height: side)
                    .opacity(0.75)
                // Wanting both: it blinks between the meal and the snack.
                let showMeal = meal && (!snack || Int(now.timeIntervalSinceReferenceDate / 0.8) % 2 == 0)
                Group {
                    if showMeal { food("tomo-meal-1", symbol: "fork.knife", color: .orange) }
                    else { food("tomo-snack-1", symbol: "birthday.cake.fill", color: .pink) }
                }
                .scaleEffect(1.7)
                .position(x: side * 129 / 256, y: side * 112 / 256)
            }
            .frame(width: side, height: side)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
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
    /// The bubble drawing's square for a character stage of `size`.
    static func side(for size: CGFloat) -> CGFloat { size * 0.13 * 4 }
}

/// The room the tomomix lives in: a square drawing (`tomo-room`) that fills
/// the whole screen, with the window cut out so the sky behind it shows
/// through. The sky follows the time of day (`tomo-sky-morning`, `-day`,
/// `-evening`, `-night`), and turns to night when the light is off.
struct TomoRoom: View {
    let simNow: Date
    let lightsOn: Bool
    let asleep: Bool
    /// Out on the grass (`tomo-outdoors`) instead of in the room. Same
    /// sky behind it, just much more of it.
    var outdoors = false

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
        ZStack {
            // The window shows the real time of day even with the light off
            // (the room itself is dimmed instead).
            TomoSky(simNow: simNow, lightsOn: true)
            if let room = TomoArt.item(outdoors ? "tomo-outdoors" : "tomo-room") {
                Image(room).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
    }

    /// Stand-in skies until the drawings exist.
    static func skyColors(_ time: TimeOfDay) -> [Color] {
        switch time {
        case .morning: return [Color(red: 1.0, green: 0.85, blue: 0.66), Color(red: 0.75, green: 0.88, blue: 0.97)]
        case .day: return [Color(red: 0.55, green: 0.80, blue: 0.97), Color(red: 0.78, green: 0.91, blue: 0.99)]
        case .evening: return [Color(red: 0.98, green: 0.62, blue: 0.48), Color(red: 0.55, green: 0.42, blue: 0.70)]
        case .night: return [Color(red: 0.08, green: 0.11, blue: 0.27), Color(red: 0.18, green: 0.20, blue: 0.42)]
        }
    }
}

/// The sky for the time of day (`tomo-sky-<time>`, the twinkling starry
/// night, or a stand-in gradient), behind the room's window and outdoors.
struct TomoSky: View {
    let simNow: Date
    var lightsOn = true
    @Environment(\.tomoRetro) private var retro

    var body: some View {
        let time = TomoRoom.timeOfDay(simNow, lightsOn: lightsOn)
        if let sky = TomoArt.item("tomo-sky-\(time.rawValue)") {
            Image(sky).resizable().scaledToFill()
        } else if time == .night {
            NightSky(now: simNow)
        } else if retro {
            // Retro Screen: flat bands instead of a smooth (dithered) gradient.
            let colors = TomoRoom.skyColors(time)
            Canvas { context, size in
                let bands = 16
                for i in 0..<bands {
                    let f = Double(i) / Double(bands - 1)
                    let c = Self.mix(colors[0], colors[1], f)
                    let y = size.height * CGFloat(i) / CGFloat(bands)
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: size.height / CGFloat(bands) + 1)),
                                 with: .color(c))
                }
            }
        } else {
            LinearGradient(colors: TomoRoom.skyColors(time), startPoint: .top, endPoint: .bottom)
        }
    }

    private static func mix(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let ca = UIColor(a), cb = UIColor(b)
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        ca.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        cb.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(f)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}

/// §10: up to 8 poops, small ones turning big after the 4th, on four
/// spots on the floor, mirrored left and right (see `spots`). While
/// `flight` runs, the newest one is shot out from behind the tomomix,
/// hits the right edge of the screen, and bounces down onto its spot. Each poop's smell waves
/// (`tomo-poop-small-wave-1..3`, cut out by the import script) flip
/// left-right about once a second, each on its own beat. While the swoosh
/// passes (`grabX`), each poop sticks to it and rides it off the screen.
struct PoopPile: View {
    let count: Int
    /// Seconds into the newest one's launch (nil when it's just sitting there).
    var flight: Double? = nil
    /// Where it shoots out from: behind the tomomix, in this view's points.
    var launch: CGPoint = .zero
    /// Draw only the flying one, while it's still behind the tomomix.
    var behindOnly = false

    /// How long the launch takes, and when it smacks the wall (after which
    /// it's drawn in front of the tomomix).
    static let flightDuration: TimeInterval = 1.4
    static let wallHit: TimeInterval = 0.3
    var now = Date()
    /// The size of one drawing's square (the poop sits in its lower half).
    var side: CGFloat = 52
    var width: CGFloat = 0
    var height: CGFloat = 0
    var grabX: CGFloat? = nil

    /// Where each poop's body sits, as fractions of the whole game screen
    /// (from the mockup, made exactly symmetric about the middle), in the
    /// order they appear, right to left.
    static let spots: [CGPoint] = [
        CGPoint(x: 0.5 + 0.404, y: 0.731),
        CGPoint(x: 0.5 + 0.2296, y: 0.806),
        CGPoint(x: 0.5 - 0.2296, y: 0.806),
        CGPoint(x: 0.5 - 0.404, y: 0.731),
    ]

    /// Big or small for each spot, right to left, with `n` poops.
    /// Big ones replace small ones in the same order they came: right first.
    static func pieces(_ n: Int) -> [Bool] {
        let big = max(0, n - 4)
        let small = min(n, 4) - big
        return (0..<big).map { _ in true } + (0..<max(0, small)).map { _ in false }
    }

    var body: some View {
        // The stage sits inside the game screen (TomoScene's indoor layout):
        // 80% of its width, starting 11.3% in; 64% of its height, 13.2% down.
        let screen = width / 0.8
        func spotCenter(_ i: Int, big: Bool) -> CGPoint {
            let spot = Self.spots[i % Self.spots.count]
            // The body's middle is lower than the drawing's middle.
            let bodyDrop = side * (big ? 0.18 : 0.23)
            return CGPoint(x: (spot.x - 0.1134) * screen, y: (spot.y - 0.1316) * screen - bodyDrop)
        }
        let e = flight ?? Self.flightDuration
        // Nothing to launch with no poops (e.g. right after switching Tamas).
        let flying = e < Self.flightDuration && count > 0
        let early = e < Self.wallHit
        // From the 5th on, a small one lands on top of a small one and
        // they turn into a big one once it has settled.
        let merging = flying && count > 4
        let merged = merging && e >= Self.settled
        let shown = merging && !merged ? count - 1 : count
        let pieces = Self.pieces(shown)
        // Never below 0: with no poops there's no newest one.
        let newestIndex = max(0, count > 4 ? count - 5 : pieces.count - 1)
        // What the flying one is, and where it lands.
        let flyerBig = !merging && (pieces.indices.contains(newestIndex) ? pieces[newestIndex] : false)
        let landing: CGPoint = {
            let c = spotCenter(newestIndex, big: flyerBig)
            return merging ? CGPoint(x: c.x, y: c.y - side * 0.17) : c
        }()
        return ZStack {
            if !behindOnly {
                ForEach(pieces.indices, id: \.self) { i in
                    let c = spotCenter(i, big: pieces[i])
                    if i == newestIndex, flying, !merging {
                        EmptyView()                    // it's the one flying in
                    } else if i == newestIndex, merged {
                        // Boing: the two become one big one.
                        let u = (e - Self.settled) / (Self.flightDuration - Self.settled)
                        piece(big: true, index: i)
                            .scaleEffect(1 + 0.3 * CGFloat(1 - u), anchor: .bottom)
                            .position(c)
                    } else {
                        piece(big: pieces[i], index: i)
                            .position(x: max(c.x, grabX ?? -.infinity), y: c.y)
                    }
                }
            }
            if flying, !merged, behindOnly == early {
                // The right edge of the game screen, less half a body.
                let wall = (0.985 - 0.1134) * screen - side * 0.3
                let f = Self.flightPose(at: e, from: launch, wall: wall, to: landing, height: height)
                piece(big: flyerBig, index: newestIndex)
                    .scaleEffect(x: f.sx, y: f.sy, anchor: f.anchor)
                    .rotationEffect(.degrees(f.spin))
                    .scaleEffect(f.grow)
                    .position(f.at)
            }
        }
        .frame(width: width, height: height)
    }

    /// When the flying one has stopped bouncing.
    static let settled: TimeInterval = 1.3

    /// The launched poop at `e` seconds: where it is, its squash, its spin,
    /// and how grown it is. Not physics, just a cartoon: shot out fast,
    /// SPLAT against the right edge, falls back down onto its spot, and
    /// bounces twice, smaller each time.
    static func flightPose(at e: Double, from a: CGPoint, wall: CGFloat, to b: CGPoint, height h: CGFloat)
        -> (at: CGPoint, sx: CGFloat, sy: CGFloat, anchor: UnitPoint, spin: Double, grow: CGFloat) {
        let hit = CGPoint(x: wall, y: a.y - h * 0.18)
        func lerp(_ p: CGFloat, _ q: CGFloat, _ u: Double) -> CGFloat { p + (q - p) * CGFloat(u) }
        let splat = 0.38, land = 0.82, bounce1 = 0.9, bounce2 = 1.12, bounce3 = 1.17, still = settled
        if e < wallHit {
            // Shot out: straight and fast, a little arc, spinning, growing
            // out from behind as it comes.
            let u = e / wallHit
            let y = lerp(a.y, hit.y, u) - h * 0.12 * CGFloat(4 * u * (1 - u))
            return (CGPoint(x: lerp(a.x, wall, u), y: y), 1, 1, .center, u * 540, 0.45 + 0.55 * CGFloat(min(1, u * 2.5)))
        }
        if e < splat {
            // Flattened against the edge.
            return (hit, 0.55, 1.3, .trailing, 0, 1)
        }
        if e < land {
            // Falls off the wall: a small pop back out, then down onto its
            // spot, spinning the other way.
            let u = (e - splat) / (land - splat)
            let pop = h * 0.12
            let y = hit.y - pop * CGFloat(u) + (b.y - hit.y + pop) * CGFloat(u * u)
            return (CGPoint(x: lerp(wall, b.x, u), y: y), 1, 1, .center, -u * 360, 1)
        }
        if e < bounce1 { return (b, 1.35, 0.65, .bottom, 0, 1) }          // squish on the floor
        if e < bounce2 {
            let u = (e - bounce1) / (bounce2 - bounce1)
            return (CGPoint(x: b.x, y: b.y - h * 0.14 * CGFloat(4 * u * (1 - u))), 0.9, 1.1, .bottom, 0, 1)
        }
        if e < bounce3 { return (b, 1.15, 0.85, .bottom, 0, 1) }
        if e < still {
            let u = (e - bounce3) / (still - bounce3)
            return (CGPoint(x: b.x, y: b.y - h * 0.045 * CGFloat(4 * u * (1 - u))), 1, 1, .bottom, 0, 1)
        }
        return (b, 1, 1, .center, 0, 1)
    }

    @ViewBuilder
    private func piece(big: Bool, index: Int) -> some View {
        let name = big ? "tomo-poop-big" : "tomo-poop-small"
        if let art = TomoArt.item(name) {
            let t = now.timeIntervalSinceReferenceDate
            ZStack {
                Image(art).resizable().scaledToFit()
                ForEach(1...3, id: \.self) { wave in
                    // About once a second, out of step with its neighbours.
                    let flipped = Int(floor(t * 1.1 + Double(wave) * 0.37 + Double(index) * 0.5)) % 2 == 1
                    if let w = TomoArt.item("\(name)-wave-\(wave)\(flipped ? "-flip" : "")") {
                        Image(w).resizable().scaledToFit()
                    }
                }
            }
            .frame(width: side, height: side)
        } else {
            let d: CGFloat = big ? 20 : 12
            Circle().fill(.brown).frame(width: d, height: d)
        }
    }
}

// MARK: - Birth and ending scenes (Animations.md §5)

/// The starry night (`tomo-starrynight`): the background color plus each
/// of the drawing's stars, which fade in and out slowly, each at its own
/// pace, so the sky gently breathes.
struct NightSky: View {
    var now: Date = Date()

    struct Star: Decodable, Sendable { let x, y, r: Double; let color: String }
    private struct Drawing: Decodable { let size: Double; let background: String; let stars: [Star] }

    /// The stars with their own pace, read once.
    private static let sky: (background: Color, size: Double, stars: [(Star, Color, period: Double, phase: Double)])? = {
        guard let data = NSDataAsset(name: "tomo-starrynight")?.data,
              let d = try? JSONDecoder().decode(Drawing.self, from: data) else { return nil }
        var rng = TomoRandom(state: 7)
        let stars = d.stars.map { star in
            // Each star takes 5-11 s to fade out and back in.
            (star, color(star.color), period: 5 + rng.unit() * 6, phase: rng.unit() * 2 * .pi)
        }
        return (color(d.background), d.size, stars)
    }()

    private static func color(_ hex: String) -> Color {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        let t = now.timeIntervalSinceReferenceDate
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if let sky = Self.sky {
                context.fill(Path(rect), with: .color(sky.background))
                // Same square as the drawing, cropped to fill if the space isn't square.
                let scale = max(size.width, size.height) / sky.size
                let dx = (size.width - sky.size * scale) / 2, dy = (size.height - sky.size * scale) / 2
                for (star, color, period, phase) in sky.stars {
                    let glow = (sin(2 * .pi * t / period + phase) + 1) / 2
                    let r = star.r * scale
                    context.fill(Path(ellipseIn: CGRect(x: dx + star.x * scale - r, y: dy + star.y * scale - r,
                                                        width: r * 2, height: r * 2)),
                                 with: .color(color.opacity(0.15 + 0.85 * glow)))
                }
                return
            }
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.2), Color(red: 0.15, green: 0.1, blue: 0.3)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var rng = TomoRandom(state: 42)
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

/// The birth's meadow (`tomo-outdoors-birth`), the same place as
/// outdoors but in stronger colors, over the night sky. Falls back to the
/// old strip of ground.
private struct Meadow: View {
    var body: some View {
        if let art = TomoArt.item("tomo-outdoors-birth") {
            Image(art).resizable().scaledToFill()
        } else {
            Ground()
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

/// §3 birth. Before anything happens, a starry night with shooting stars
/// passing now and then; the player catches one with a tap. It hangs
/// there while they say their name (first time only), then falls (the
/// intro, skippable) and pulses faster and faster until it's born.
struct TomoBirthScene: View {
    let bornAt: Date
    let simNow: Date
    let now: Date
    let intro: TomoMoment?
    /// The sky is waiting for the player to catch a star.
    var waiting = false
    /// Where the star was caught (fractions of the screen), and when.
    var caught: CGPoint?
    var caughtAt: Date?

    /// A caught star glides up here and waits, above the name card.
    static let hover = CGPoint(x: 0.5, y: 0.17)

    /// The caught star's spot at `now`: from where it was caught to the
    /// hover spot in a few steps (0.6 s).
    private func caughtSpot(_ c: CGPoint) -> CGPoint {
        let p = min(1, max(0, now.timeIntervalSince(caughtAt ?? now) / 0.6))
        let e = 1 - (1 - p) * (1 - p)
        return CGPoint(x: c.x + (Self.hover.x - c.x) * e, y: c.y + (Self.hover.y - c.y) * e)
    }

    /// The intro's falling part starts this far in (the part before it is
    /// the sky and the shooting star, which the player now catches).
    static let fallStart: TimeInterval = 3.5

    /// Where the fallen star rests: on the meadow of `tomo-outdoors-birth`,
    /// just below the top of the grass (y = 338 of 596).
    static let landing = CGPoint(x: 0.5, y: 367.0 / 596)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                NightSky(now: now)
                if waiting {
                    if let c = caught {
                        // Caught: it waits, twinkling, for the name.
                        let spot = caughtSpot(c)
                        star(trail: false, size: 26)
                            .scaleEffect(1 + 0.12 * sin(now.timeIntervalSinceReferenceDate * 5))
                            .position(x: spot.x * w, y: spot.y * h)
                    } else {
                        let t = now.timeIntervalSinceReferenceDate
                        if let s = Self.shootingStar(at: t) {
                            // The trail is where the star really was a moment
                            // ago, so it curves with the arc and stretches when
                            // the star speeds up.
                            StarTrail(width: 22 * 0.75) { age in
                                Self.shootingStar(at: t - age)?.point
                            }
                            star(trail: false, size: 22)
                                .position(x: s.point.x * w, y: s.point.y * h)
                        }
                        Text("Catch a shooting star")
                            .font(.tomo(.footnote))
                            .foregroundStyle(.white.opacity(0.55 + 0.2 * sin(now.timeIntervalSinceReferenceDate * 1.5)))
                            .position(x: w / 2, y: h * 0.88)
                    }
                } else if let m = intro {
                    let e = m.elapsed(at: now)
                    if e >= Self.fallStart {
                        let p = min(1, (e - Self.fallStart) / (m.duration - Self.fallStart))
                        // From where it waited (or from above, the old way).
                        let from = caught == nil ? CGPoint(x: 0.5, y: -0.1) : Self.hover
                        let to = Self.landing
                        Meadow()
                        let fall = m.duration - Self.fallStart
                        let spot = { (q: Double) -> CGPoint in
                            CGPoint(x: from.x + (to.x - from.x) * q, y: from.y + (to.y - from.y) * q * q)
                        }
                        // Its real path a moment ago trails behind it.
                        StarTrail(width: (26 + 8 * p) * 0.75) { age in
                            let q = (e - age - Self.fallStart) / fall
                            return q < 0 ? nil : spot(min(1, q))
                        }
                        .opacity(1 - max(0, p - 0.85) / 0.15)
                        star(trail: false, size: 26 + 8 * p)
                            .position(x: w * spot(p).x, y: h * spot(p).y)
                    }
                } else {
                    let left = bornAt.timeIntervalSince(simNow)
                    let total = TomoRules.starPulseSeconds
                    // While it pulses, the starry night gives way to the
                    // real sky of this time of day.
                    TomoSky(simNow: simNow)
                        .opacity(min(1, max(0, (total - left) / total)))
                    Meadow()
                    // The last moments: it hops up, bursts, and all goes white.
                    let hop = min(1, max(0, (1.3 - left) / 0.3))
                    let burst = min(1, max(0, (0.9 - left) / 0.9))
                    PulsingStar(timeLeft: left)
                        .position(x: w * Self.landing.x,
                                  y: h * Self.landing.y - h * 0.08 * CGFloat(1 - (1 - hop) * (1 - hop)))
                    if burst > 0 {
                        TomoExplosion(q: burst, side: w * 0.5)
                            .position(x: w * Self.landing.x, y: h * (Self.landing.y - 0.08))
                        Color.white.opacity(burst)
                    }
                }
            }
        }
    }

    /// The shooting star in the sky at `t`, if one is passing. One every
    /// few seconds, each crossing in 1.6 s at its own height and
    /// direction; slow and big enough to catch.
    static func shootingStar(at t: TimeInterval) -> (point: CGPoint, leftward: Bool, angle: Double)? {
        let period = 3.2, flight = 1.6
        let n = Int(floor(t / period))
        let e = t - Double(n) * period
        guard e < flight else { return nil }
        var rng = TomoRandom(state: UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15 &+ 17)
        let leftward = rng.unit() < 0.5
        let y0 = 0.3 + rng.unit() * 0.22
        let lift = 0.14 + rng.unit() * 0.06
        // Eased: it eases in, speeds through the middle, eases out.
        let p = e / flight
        let q = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        // A parabola: up over the sky and gently down, a little lower at the end.
        let x = -0.1 + 1.2 * q
        let y = y0 - lift * 4 * q * (1 - q) + 0.08 * q
        // Direction of travel (as if going right), so the trail follows the curve.
        let angle = atan2(-lift * 4 * (1 - 2 * q) + 0.08, 1.2)
        return (CGPoint(x: leftward ? 1 - x : x, y: y), leftward, angle)
    }

    /// The star a tap at `point` (fractions of the screen) catches at
    /// `t`, if any, and where it is now. Forgiving: the target is a bit
    /// bigger than the star, and a tap where it was a moment ago (fingers
    /// lag behind a moving star) still counts.
    static func caughtStar(by point: CGPoint, at t: TimeInterval) -> CGPoint? {
        for lag in [0, 0.12, 0.24, 0.36] {
            guard let s = shootingStar(at: t - lag),
                  hypot(point.x - s.point.x, point.y - s.point.y) < 0.14 else { continue }
            return shootingStar(at: t)?.point ?? s.point
        }
        return nil
    }

    /// The star, with or without its trail, centered on its head (the
    /// 4-point star) so it can be placed, flipped and turned around it.
    /// `size` is roughly the head's width.
    @ViewBuilder
    private func star(trail: Bool, size: CGFloat) -> some View {
        if trail, let art = TomoArt.item("tomo-shooting-star") {
            // The drawing is 472 x 180 with the head's center at (416, 108).
            let w = size * 1.5 * 472 / 108, h = w * 180 / 472
            Image(art).resizable().frame(width: w, height: h)
                .offset(x: w * (0.5 - 416.4 / 472), y: h * (0.5 - 107.7 / 180))
        } else if !trail, let art = TomoArt.item("tomo-star-fallen") {
            Image(art).resizable().scaledToFit().frame(width: size * 1.5, height: size * 1.9)
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

/// A shooting star's trail: the path it really took over the last
/// moments (`point(age)`, fractions of the screen, nil before it
/// appeared), drawn as a soft glow and a brighter core that both taper
/// and fade toward the tail, in the star's pale yellow (#F9FA93).
private struct StarTrail: View {
    /// Width at the star's end, in points.
    let width: CGFloat
    let point: (TimeInterval) -> CGPoint?

    var body: some View {
        Canvas { context, size in
            let steps = 24, span = 0.4                       // the last 0.4 s
            var points: [CGPoint] = []
            for i in 0...steps {
                guard let p = point(span * Double(i) / Double(steps)) else { break }
                points.append(CGPoint(x: p.x * size.width, y: p.y * size.height))
            }
            guard points.count > 1 else { return }
            let yellow = Color(red: 0xF9 / 255, green: 0xFA / 255, blue: 0x93 / 255)
            for i in 1..<points.count {
                let fade = 1 - Double(i) / Double(points.count)   // 1 at the star, 0 at the tail
                var segment = Path()
                segment.move(to: points[i - 1])
                segment.addLine(to: points[i])
                context.stroke(segment, with: .color(yellow.opacity(0.25 * fade)),
                               style: StrokeStyle(lineWidth: width * CGFloat(fade), lineCap: .round))
                context.stroke(segment, with: .color(yellow.opacity(0.55 * fade)),
                               style: StrokeStyle(lineWidth: width * 0.4 * CGFloat(fade), lineCap: .round))
            }
        }
        .allowsHitTesting(false)
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
        // Centered on its landing spot; it swells upward from its base.
    }
}

/// §12 ending: the tomomix fades as the night falls and its star appears.
struct TomoEndingScene: View {
    let character: TomoCharacter
    var name: String = ""
    let ageYears: Int
    let now: Date
    /// After a first tap: "tap again to shoot a new star" shows until then.
    var hintUntil: Date? = nil
    /// 0-1 while the transition plays; nil once it has settled.
    let transition: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let size = h * 0.86
            let p = transition ?? 1
            let t = now.timeIntervalSinceReferenceDate
            let glow = (sin(t * 1.8) + 1) / 2
            let bob = sin(t * 1.2) * h * 0.02
            let shown = max(0, (p - 0.5) * 2)          // star and words fade in
            ZStack {
                Color(.systemBackground)
                NightSky(now: now).opacity(p)
                // It fades to a faint ghost as the night comes, leaving its star.
                // It rises from where it stood until the middle of its real
                // shape (its idle drawing's outline) is the screen's center.
                let box = TomoArt.imageName(character, .idle, 1).flatMap { TomoArt.inkBounds($0) }
                    ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                let centered = CGPoint(x: geo.size.width / 2 - (box.midX - 0.5) * size,
                                       y: h / 2 - (box.midY - 0.5) * size)
                let standing = CGPoint(x: geo.size.width / 2, y: h - size / 2)
                TomoSprite(character: character, pose: .idle)
                    .frame(width: size, height: size)
                    .opacity(1 - 0.75 * p)
                    .blur(radius: CGFloat(p))
                    .position(x: standing.x + (centered.x - standing.x) * CGFloat(p),
                              y: standing.y + (centered.y - standing.y) * CGFloat(p))
                // Its star (the Tomomix star) in the middle, glowing and
                // floating gently, with its name above and its age below.
                // The star alone sits at the exact center; the name hangs
                // above it and the age below, without pushing it off center.
                Group {
                    if let art = TomoArt.item("tomo-star-fallen") {
                        Image(art).resizable().scaledToFit()
                    } else {
                        Image(systemName: "star.fill").resizable().scaledToFit().foregroundStyle(.yellow)
                    }
                }
                .frame(width: h * 0.16, height: h * 0.2)
                .shadow(color: Color(red: 1, green: 0.92, blue: 0.38).opacity(0.9), radius: 6 + 14 * glow)
                .scaleEffect(0.96 + 0.06 * glow)
                .offset(y: bob)
                .position(x: geo.size.width / 2, y: h / 2)
                .opacity(shown)
                // The name just below the top row of icons, the age just above
                // the bottom row (each row is the top/bottom 16% of the screen).
                if !name.isEmpty {
                    Text(name)
                        .font(.tomo(.largeTitle))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 16)
                        .position(x: geo.size.width / 2, y: h * 0.23)
                        .opacity(shown)
                }
                Text(ageYears == 1 ? "1 year old" : "\(ageYears) years old")
                    .font(.tomo(.headline))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: geo.size.width / 2, y: h * 0.79)
                    .opacity(shown)
                // Above the age, after a first tap; fades out at the end of its 2 s.
                if let until = hintUntil, now < until {
                    Text("tap again to shoot a new star")
                        .font(.tomo(.footnote))
                        .foregroundStyle(.white.opacity(0.9))
                        .position(x: geo.size.width / 2, y: h * 0.72)
                        .opacity(min(1, until.timeIntervalSince(now) / 0.5))
                }
            }
        }
    }
}


/// Medicine, Tomomix style: "sana sana, culito de rana". The healing frog
/// (`tomo-healing-frog`) pops out of the window's lower-right pane (from
/// the left edge outdoors), hops over to the tomomix, turns its back, toots
/// a little cloud (`tomo-healing-cloud`) at its face, and hops back home.
struct TomoFrog: View {
    let elapsed: TimeInterval
    /// The left edge of the tomomix's face, on the stage.
    let face: CGPoint
    let stageWidth: CGFloat
    /// The characters' drawing size on this stage: in the room the frog is
    /// as big as an adult tomomix (silly big).
    let petSize: CGFloat
    var outdoors = false

    static let duration: TimeInterval = 4.2
    /// When the toot happens.
    static let toot: TimeInterval = 1.8

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ q: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q)
    }

    /// A point on the game screen (fractions) in stage coordinates: the stage
    /// is 80% of the screen wide, 11.3% in, 13.2% down.
    private func stage(_ x: Double, _ y: Double) -> CGPoint {
        let screen = stageWidth / 0.8
        return CGPoint(x: (x - 0.1134) * screen, y: (y - 0.1316) * screen)
    }

    private var screen: CGFloat { stageWidth / 0.8 }
    /// The 512 drawing's square: the frog's outline is about 0.58 of it
    /// tall, an adult's about 0.8 of its own square, so this matches them.
    private var side: CGFloat { petSize * 1.35 * 0.8 }        // 20% under adult size
    /// Small enough to fit through the window pane.
    private var paneScale: CGFloat { screen * 0.12 / side }
    /// Its back end (the yellow bit, where the cloud comes out) is at
    /// (0.6, 0.62) of the drawing: put it just left of the face.
    private var spot: CGPoint { CGPoint(x: face.x - screen * 0.03 - side * 0.1, y: face.y - side * 0.12) }
    /// The window's lower-right pane (or off the left edge outdoors).
    private var home: CGPoint { outdoors ? stage(-0.12, 0.66) : stage(0.2325, 0.397) }

    /// Where it is, how big, which way it faces, and how high it hops.
    /// Like the tomomixes it moves in steps: three hops, each one an
    /// instant jump to the next spot, up for a moment, then down.
    private var state: (pos: CGPoint, scale: CGFloat, facingRight: Bool, hop: CGFloat) {
        let e = elapsed
        let out = 0.45, there = Self.toot - 0.15, leave = Self.toot + 0.9, gone = Self.duration - 0.45
        let hopHeight = petSize * 0.12
        // Which of the 3 hops it's on (1-3) and whether it's still up in the air.
        func hops(_ q: Double) -> (step: Int, up: Bool) {
            let f = q * 3
            let step = min(3, Int(f) + 1)
            return (step, f - Double(step - 1) < 0.45)
        }
        if e < out {                                           // pops out of the pane, in 2 steps
            return (home, paneScale * (e < out / 2 ? 0.5 : 1), true, 0)
        } else if e < there {                                  // three hops over, big once in the room
            let h = hops((e - out) / (there - out))
            return (Self.lerp(home, spot, Double(h.step) / 3), 1, true, h.up ? hopHeight : 0)
        } else if e < leave {                                  // back turned: toot!
            return (spot, 1, false, 0)
        } else if e < gone {                                   // three hops home
            let h = hops((e - leave) / (gone - leave))
            let last = h.step == 3
            return (Self.lerp(spot, home, Double(h.step) / 3), last ? paneScale : 1, false, h.up ? hopHeight : 0)
        } else {                                               // back into the pane, in 2 steps
            return (home, paneScale * (e < gone + (Self.duration - gone) / 2 ? 0.5 : 0), false, 0)
        }
    }

    /// Fades in smoothly while it comes through the window, and out while
    /// it goes back through.
    private var fade: Double {
        let out = 0.45, gone = Self.duration - 0.45
        if elapsed < out { return elapsed / out }
        if elapsed >= gone { return max(0, 1 - (elapsed - gone) / (Self.duration - gone)) }
        return 1
    }

    var body: some View {
        let e = elapsed
        let (pos, scale, facingRight, hop) = state
        ZStack {
            if let frog = TomoArt.item("tomo-healing-frog") {
                Image(frog).resizable().scaledToFit()
                    .frame(width: side, height: side)
                    .scaleEffect(x: facingRight ? -scale : scale, y: scale)
                    .opacity(fade)
                    .position(x: pos.x, y: pos.y - hop)
            }
            // The cloud puffs out of its back, swells, drifts to the face and fades.
            // Unlike the frog, the cloud moves smoothly: it squeezes out of its
            // back and glides to the right, onto the face, swelling as it goes.
            if e >= Self.toot, e < Self.toot + 1.1, let cloud = TomoArt.item("tomo-healing-cloud") {
                let q = (e - Self.toot) / 1.1
                let glide = 1 - (1 - q) * (1 - q)                 // fast out, then slows
                Image(cloud).resizable().scaledToFit()
                    .frame(width: side, height: side)
                    .scaleEffect(0.2 + 0.9 * glide, anchor: UnitPoint(x: 0.6, y: 0.62))
                    .opacity(q < 0.65 ? 1 : (1 - q) / 0.35)
                    .position(x: spot.x + side * 0.3 * glide, y: spot.y)
            }
        }
        .allowsHitTesting(false)
    }
}
