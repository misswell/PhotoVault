import SwiftUI

/// The app's shared motion vocabulary.
///
/// The point is not that every animation has an identical duration; it is that
/// each one belongs to a named semantic class so the app never accumulates a
/// dozen slightly different springs:
///
/// - `micro`:    immediate feedback on a control (chevron, favorite, mute).
/// - `state`:    a local view state change (expand, collapse, layout mode).
/// - `viewer…`:  the full-screen photo viewer's presentation, chrome and
///               cancellation physics. Values are the ones already tuned in
///               `ViewerMotion`; this type is where they are declared now.
/// - `organizer…`: the swipe-card physics of the random organizer, which are
///               intentionally heavier and more physical than UI state.
enum AppMotion {
    /// Chevrons, favorite toggles, mute, selection and toolbar icon swaps.
    static let micro = Animation.easeOut(duration: 0.16)

    /// Local expand/collapse and layout-mode changes.
    static let state = Animation.snappy(duration: 0.22, extraBounce: 0)

    /// Full-screen viewer presentation.
    static let viewerPresentation = Animation.spring(
        response: 0.44,
        dampingFraction: 0.88,
        blendDuration: 0.04
    )

    /// Viewer top/bottom chrome show/hide.
    static let viewerChrome = Animation.spring(
        response: 0.30,
        dampingFraction: 0.92,
        blendDuration: 0
    )

    /// Viewer dismissal cancellation (a pull-down that did not commit).
    static let viewerCancellation = Animation.spring(
        response: 0.40,
        dampingFraction: 0.82,
        blendDuration: 0.02
    )

    /// Random organizer: a committed decision (keep / discard / favourite).
    static let organizerCommit = Animation.spring(
        response: 0.40,
        dampingFraction: 0.90
    )

    /// Random organizer: a card springing back to the deck.
    static let organizerReset = Animation.spring(
        response: 0.38,
        dampingFraction: 0.84
    )

    /// Short, non-bouncy fallback used when the user asks to reduce motion.
    static let reducedMotion = Animation.easeOut(duration: 0.18)
}

/// Layout constants that several screens share. These are the handful of
/// values that were previously retyped (12 / 18 / 22 / 24 / 30 / 46) across
/// the grid, viewer and organizer.
enum AppLayout {
    static let compactRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let prominentRadius: CGFloat = 24
    static let minimumTapSize: CGFloat = 44
    static let viewerControlSize: CGFloat = 46
}
