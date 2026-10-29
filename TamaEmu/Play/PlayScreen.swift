import SwiftUI

struct PlayScreen: View {
    @State private var viewModel = PlayViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("TamaEmu")
                .font(.title.bold())
            LCDView(image: viewModel.lcdImage)
                .frame(maxWidth: 280)
                .border(Color.gray)
            Text(viewModel.deviceSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

#Preview {
    PlayScreen()
}
