import SwiftUI
import TamaCore

/// One gallery page: a single Tama's LCD + buttons. The overflow menu
/// (pause, settings, delete) lives on the enclosing NavigationStack in
/// TamaGalleryView, not here — a `.toolbar` defined per page would attach to
/// every page the page-style TabView keeps alive for swiping, and right
/// after launch (before the TabView settles on its initial selection) that
/// could show two pages' toolbars — and so two overflow buttons — at once.
/// Tapping the LCD toggles pause — this can only ever be called on the page
/// currently on screen, so PlayViewModel's togglePause() is safe to act on
/// its own engine directly.
struct TamaPageView: View {
    let viewModel: PlayViewModel
    let ambientBackgroundEnabled: Bool

    var body: some View {
        pageContent
    }

    private var pageContent: some View {
        VStack(spacing: 16) {
            ZStack {
                LCDView(image: viewModel.lcdImage)
                    .frame(maxWidth: 280)
                    .screenGlow(color: viewModel.lcdGlowColor)

                if viewModel.isPaused {
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                        Text("Paused — tap to resume")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if viewModel.isLoading {
                    VStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                        Text("Catching up…")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            // On the whole stack, not just LCDView — otherwise tapping
            // directly on the "Paused — tap to resume" badge itself (the
            // single most likely place to tap) is swallowed by the badge's
            // own opaque background instead of reaching the gesture below it.
            .contentShape(Rectangle())
            .onTapGesture { viewModel.togglePause() }
            // Floats above the LCD's own frame (overlay, not layout) so it
            // never shifts the title/ButtonPad position while visible.
            .overlay(alignment: .top) {
                if let translatedText = viewModel.translatedText {
                    TranslationBubble(text: translatedText) {
                        viewModel.dismissTranslation()
                    }
                    .offset(y: -64)
                    .task(id: translatedText) {
                        try? await Task.sleep(for: .seconds(6))
                        viewModel.dismissTranslation()
                    }
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.translatedText)

            if ambientBackgroundEnabled {
                Text(viewModel.selectedDevice.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.25))
            } else {
                Text(viewModel.selectedDevice.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ButtonPad(
                onPress: { viewModel.pressButton($0) },
                onRelease: { viewModel.releaseButton($0) }
            )
            .disabled(viewModel.isLoading || viewModel.isPaused)
            .opacity(viewModel.isLoading || viewModel.isPaused ? 0.4 : 1)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
}
