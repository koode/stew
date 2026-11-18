import CoreGraphics

/// Where the panel goes on a screen. `visible` is the screen's visible frame (without the
/// menu bar and the Dock), in AppKit coordinates: y grows upwards.
public enum PanelPlacement {
    public static let margin: CGFloat = 14

    /// The values of `StewConfig.position`, in the order Settings lists them.
    public static let positions = ["top-right", "top-center", "top-left", "bottom-right", "bottom-center", "bottom-left"]

    /// The panel sits at the bottom edge and grows upwards.
    public static func isBottom(_ position: String) -> Bool { position.hasPrefix("bottom-") }

    /// The configured spot on the screen. An unknown value counts as top right.
    public static func corner(_ position: String, size: CGSize, visible: CGRect) -> CGRect {
        let x: CGFloat
        switch position {
        case "top-center", "bottom-center": x = visible.midX - size.width / 2
        case "top-left", "bottom-left": x = visible.minX + margin
        default: x = visible.maxX - size.width - margin
        }
        let y = isBottom(position) ? visible.minY + margin : visible.maxY - size.height - margin
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The spot a dragged panel snaps to: the left, middle or right third of the screen, and
    /// the top or bottom half, by where the panel's centre was let go.
    public static func nearest(to frame: CGRect, in visible: CGRect) -> String {
        let third = visible.width / 3
        let column: String
        if frame.midX < visible.minX + third {
            column = "left"
        } else if frame.midX < visible.minX + 2 * third {
            column = "center"
        } else {
            column = "right"
        }
        let row = frame.midY < visible.midY ? "bottom" : "top"
        return "\(row)-\(column)"
    }

    /// `frame` at a new size, keeping the edges its spot is anchored to: the top or bottom
    /// edge, and the left edge, the centre or the right edge.
    public static func resized(_ frame: CGRect, to size: CGSize, position: String) -> CGRect {
        let x: CGFloat
        switch position {
        case "top-center", "bottom-center": x = frame.midX - size.width / 2
        case "top-left", "bottom-left": x = frame.minX
        default: x = frame.maxX - size.width
        }
        let y = isBottom(position) ? frame.minY : frame.maxY - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Moves `frame` the least distance that puts it fully inside `visible`. A frame larger
    /// than the screen keeps its top left corner on screen, where the header is.
    public static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        result.origin.y = min(visible.maxY - frame.height, max(frame.minY, visible.minY))
        return result
    }
}
