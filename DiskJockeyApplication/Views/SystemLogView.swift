import SwiftUI

struct SystemLogView: View {
    @EnvironmentObject var appLogModel: AppLogModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("System Log")
                .font(.title2)
                .bold()
                .padding(.bottom, 8)
            ScrollView {
                Text(appLogModel.messages.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .padding(.top, 4)
        }
        .padding()
    }
}
