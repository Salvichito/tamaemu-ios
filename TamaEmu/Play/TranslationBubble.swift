import SwiftUI

/// A speech-bubble callout for showing the on-device translation above the
/// LCD — floats over the page via an overlay rather than taking up layout
/// space, so it never shifts the device title or ButtonPad position while
/// playing. Tap anywhere on it to dismiss early; TamaPageView also
/// auto-dismisses it after a few seconds unread.
struct TranslationBubble: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)

            BubbleTail()
                .fill(.regularMaterial)
                .frame(width: 16, height: 8)
        }
        .frame(maxWidth: 240)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
