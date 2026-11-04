import AppKit
import Observation

/// Recall's window and its pop-ups fit the screen the window is on (REC-73, GitHub #52).
///
/// The window is 800 points tall at least and the large pop-ups (Settings, Help & FAQ, About,
/// Licenses, What's New) 760, which needs about 830 points of screen below the menu bar. A display
/// set toward Larger Text in System Settings › Displays leaves less: about 717 on a 14-inch
/// MacBook Pro at 1147 × 745, 800 on a 13-inch MacBook Air at 1280 × 832, and less again above a
/// Dock at the bottom. On such a screen the window's minimum shrinks to the room left
/// (AppDelegate.fitToScreen), the large pop-ups stay 40 points shorter than that, and their
/// scrolling parts take the difference. A small pop-up (FittedSheet) grows no taller than a large
/// one: past that its content scrolls above its buttons. Screens with room are unchanged.
@MainActor @Observable final class WindowFit {
    static let shared=WindowFit()
    /// The window's smallest and starting size, where the screen has room for it.
    nonisolated static let window=CGSize(width:540,height:800)
    /// The large pop-ups' height where the screen has room: 760 fits every Settings tab at its
    /// tallest (Graphics while Battle.net is open, 745; Display with two monitors, 714), so
    /// switching tabs moves nothing (owner, 2026-10-14). On a shorter screen they stay one size,
    /// shorter, and the page scrolls.
    nonisolated static let sheet:CGFloat=760
    /// The window's 800 less a large pop-up's 760: the space macOS leaves around a pop-up.
    nonisolated static let sheetMargin:CGFloat=window.height-sheet
    /// The shortest window whose large pop-ups still show all of their fixed parts (heading, tabs,
    /// search, buttons) and some of what scrolls. Measured on the private preview with
    /// --preview-visible-height: What's New has the most fixed (about 320 points), and in a
    /// 360-point pop-up still shows one item of its list. Every Displays setting of every Mac
    /// leaves more room, down to about 444 on a 13-inch MacBook Air at 1024 × 640 with the
    /// largest Dock below.
    nonisolated static let smallest:CGFloat=400
    /// The window content's minimum height on the screen it is on.
    var windowHeight:CGFloat=window.height
    /// How tall a large pop-up is, and how tall a small one can grow before it scrolls.
    var sheetHeight:CGFloat { windowHeight-Self.sheetMargin }
    /// The window content's minimum for a screen whose visible part (below the menu bar, above a
    /// Dock at the bottom) is `visible` points tall, under a title bar `titleBar` tall.
    nonisolated static func windowHeight(visible:CGFloat,titleBar:CGFloat)->CGFloat {
        max(smallest,min(window.height,(visible-titleBar).rounded(.down)))
    }
    /// Where the window goes on a screen: no taller than the visible part (nor shorter than its
    /// minimum, `minimumFrame`), and moved inside it if it reaches past the menu bar, the Dock or
    /// the bottom edge. A window that already fits stays where it is.
    nonisolated static func fitted(_ frame:CGRect,visible:CGRect,minimumFrame:CGFloat)->CGRect {
        var fitted=frame
        fitted.size.height=max(minimumFrame,min(frame.height,visible.height))
        fitted.origin.y=max(visible.minY,min(frame.minY,visible.maxY-fitted.height))
        // Taller than the screen only below `smallest`: keep the title bar under the menu bar.
        if fitted.height > visible.height { fitted.origin.y=visible.maxY-fitted.height }
        return fitted
    }
}
