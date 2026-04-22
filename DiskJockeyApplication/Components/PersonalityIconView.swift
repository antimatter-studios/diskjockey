import SwiftUI
import DiskJockeyLibrary

/// Renders a `PersonalityIcon` as either an SF Symbol or a template
/// asset-catalog image. Both branches honor the ambient
/// `.foregroundStyle(...)` so the two icon kinds drop in wherever the
/// other fits without the call site branching on `.sfSymbol` vs
/// `.asset`.
///
/// Sizing convention: SF Symbols size via `.font(...)` — the system
/// draws at the resolved font size. Asset templates need `.resizable()`
/// and an explicit frame. To keep parity at call sites, this view pairs
/// `.resizable().scaledToFit()` on the asset branch so a surrounding
/// `.frame(width:height:)` sizes both the same way.
public struct PersonalityIconView: View {
    private let icon: PersonalityIcon

    public init(_ icon: PersonalityIcon) {
        self.icon = icon
    }

    public var body: some View {
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name)
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
        @unknown default:
            Image(systemName: "questionmark.square.dashed")
        }
    }
}
