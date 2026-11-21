import SwiftUI
import UIKit
import TamaCore

/// The first screen when there are no pets at all: start the built-in
/// Tomomix, or bring a toy's own ROM. A night sky, matching the starry
/// night Tomomix itself starts in.
struct WelcomeView: View {
    var onStartTomomix: () -> Void
    var onImported: (TamaDevice) -> Void

    @State private var showingImport = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 20)
                VStack(spacing: 8) {
                    Text("TamaEmu")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("Make a choice")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 18)

                WelcomeChoice(
                    title: "Adopt a Tomomix",
                    detail: "An original little pet inspired by the classics.",
                    tint: Color(red: 1.0, green: 0.78, blue: 0.25),
                    art: { TwinklingStar() },
                    action: onStartTomomix
                )
                .offset(y: appeared ? 0 : 30)
                .opacity(appeared ? 1 : 0)

                WelcomeChoice(
                    title: "Import a ROM",
                    detail: "Play a toy you own, from its own ROM file.",
                    tint: Color(red: 0.55, green: 0.75, blue: 1.0),
                    art: {
                        Image(systemName: "memorychip.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                    },
                    action: { showingImport = true }
                )
                .offset(y: appeared ? 0 : 30)
                .opacity(appeared ? 1 : 0)

                Text("Choose one to get started. You can add more virtual pets and switch between them later.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .opacity(appeared ? 1 : 0)
                Spacer(minLength: 20)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
                    NightSky(now: timeline.date)
                }
                .ignoresSafeArea()
            }
            .navigationDestination(isPresented: $showingImport) {
                FirmwareImportView(devices: DeviceCatalog.all()) { device, _ in
                    onImported(device)
                }
                .navigationTitle("Import a ROM")
                .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear {
                withAnimation(.spring(duration: 0.8, bounce: 0.3).delay(0.15)) { appeared = true }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct WelcomeChoice<Art: View>: View {
    let title: String
    let detail: String
    let tint: Color
    @ViewBuilder let art: () -> Art
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                art()
                    .frame(width: 64, height: 64)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
                    Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.headline).foregroundStyle(tint)
            }
            .padding(18)
            // The card's own color at 20%, edge to edge, no outline.
            .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(WelcomePressStyle())
    }
}

private struct WelcomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// A star that glows and bobs, with a little shooting star crossing it.
private struct TwinklingStar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let glow = (sin(t * 2.4) + 1) / 2
            let pass = (t.truncatingRemainder(dividingBy: 3.0)) / 3.0
            ZStack {
                Group {
                    // The Tomomix star (cut from tomo-shootingstar by the import script).
                    if UIImage(named: "tomo-star-fallen") != nil {
                        Image("tomo-star-fallen").resizable().scaledToFit().frame(width: 30, height: 38)
                    } else {
                        Image(systemName: "star.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.3))
                    }
                }
                    .shadow(color: .yellow.opacity(0.9), radius: 3 + 7 * glow)
                    .scaleEffect(0.92 + 0.12 * glow)
                    .offset(y: -2 * sin(t * 1.6))
                if pass < 0.4 {
                    let p = pass / 0.4
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 18, height: 2)
                        .rotationEffect(.degrees(20))
                        .offset(x: -26 + 52 * p, y: -24 + 14 * p)
                        .opacity(1 - p)
                }
            }
        }
    }
}
