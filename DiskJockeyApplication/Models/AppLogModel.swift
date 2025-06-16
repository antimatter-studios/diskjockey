import Foundation

class AppLogModel: ObservableObject {
    @Published var messages: [String] = []
    func log(_ msg: String) {
        messages.append(msg)
    }
}
