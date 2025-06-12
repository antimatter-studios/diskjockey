import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About Disk Jockey")
                .font(.largeTitle)
                .bold()
            Text("Disk Jockey\nA cross-platform file and mount manager.\n\nVersion 1.0\nBy Chris Thomas.")
                .font(.body)
            Spacer()
        }
        .padding()
    }
}
