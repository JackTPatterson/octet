import Foundation

/// Pixel sizes can be transiently empty or non-finite during AppKit layout.
/// Validate before converting to the renderer's unsigned dimensions.
struct TerminalPixelSize: Equatable {
    let width, height: UInt32

    init?(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= CGFloat(UInt32.max), size.height <= CGFloat(UInt32.max) else { return nil }
        width = UInt32(size.width)
        height = UInt32(size.height)
    }
}
