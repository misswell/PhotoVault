import Foundation

/// One place for "how long do we stay silent before telling the user something
/// is loading". PhotoKit and iCloud hand back degraded frames in well under
/// this window for anything already local, so a spinner that appears during it
/// is always a flash, never information.
enum AppLoadingPolicy {
    /// Loading feedback is withheld for this long. Applies to spinners that
    /// would otherwise appear over an image surface (grid cells, viewer pages).
    static let indicatorDelay: Duration = .milliseconds(450)

    /// A grid cell never shows a spinner at all: it paints a static
    /// placeholder (its grouped background) and fills in when the thumbnail
    /// arrives. Kept as a named constant so the rule is discoverable.
    static let gridUsesStaticPlaceholder = true
}
