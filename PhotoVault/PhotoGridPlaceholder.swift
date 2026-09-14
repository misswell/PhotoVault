import SwiftUI

/// The single static placeholder used wherever a grid thumbnail has not
/// arrived yet — the system library, the album grids and the folder-album
/// grids all share it.
///
/// A grid never shows a spinner per cell: scrolling a large library would
/// otherwise paint dozens of simultaneously animating indicators, which costs
/// frames and reads as breakage rather than progress. A calm neutral tile
/// carries the same "not loaded yet" meaning at no animation cost.
struct PhotoGridPlaceholder: View {
    var cornerRadius: CGFloat = AppLayout.compactRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemFill))
    }
}
