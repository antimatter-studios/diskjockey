import SwiftUI
import DiskJockeyLibrary

/// Renders a `PersonalityIcon` as a template asset-catalog image.
/// Honors the ambient `.foregroundStyle(...)`, and pairs
/// `.resizable().scaledToFit()` so a surrounding
/// `.frame(width:height:)` sizes the icon predictably.
public struct PersonalityIconView: View {
    private let icon: PersonalityIcon

    public init(_ icon: PersonalityIcon) {
        self.icon = icon
    }

    public var body: some View {
        switch icon {
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
        }
    }
}
