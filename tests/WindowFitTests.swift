import AppKit

// The window and pop-up sizes for the screen the window is on (WindowFit, REC-73, GitHub #52),
// and where the window goes on it. Visible heights are the room below the menu bar (and above a
// Dock at the bottom) at real Displays settings.
@main struct WindowFitTests {
    static func main() {
        // The title bar of Recall's window, as macOS draws it here.
        let titleBar=NSWindow.frameRect(forContentRect:NSRect(x:0,y:0,width:600,height:600),styleMask:[.titled,.closable,.miniaturizable,.resizable]).height-600
        precondition(titleBar > 20 && titleBar < 40,"title bar \(titleBar)")
        func height(_ visible:CGFloat)->CGFloat { WindowFit.windowHeight(visible:visible,titleBar:titleBar) }

        // Screens with room keep 800 and the pop-ups 760, as before: 14-inch MacBook Pro at
        // Default (1512 × 982), a 1080p or 1440p monitor, a 13-inch MacBook Air at Default
        // (1470 × 956), the M1 Air at Default (1440 × 900) with the Dock hidden.
        for visible:CGFloat in [950,1055,1415,924,876] {
            precondition(height(visible) == 800,"\(visible) → \(height(visible))")
        }
        precondition(WindowFit.window == CGSize(width:540,height:800) && WindowFit.sheet == 760 && WindowFit.sheetMargin == 40)

        // GitHub #52: 14-inch MacBook Pro at 1147 × 745, about 717 points below the menu bar.
        // The window fits under its title bar and a large pop-up 40 points inside it.
        let reporter=height(717)
        precondition(reporter == (717-titleBar).rounded(.down) && reporter+titleBar <= 717)
        precondition(reporter-WindowFit.sheetMargin < 760 && reporter-WindowFit.sheetMargin > 600)
        // 13-inch MacBook Air at 1280 × 832; a 13-inch Air at 1024 × 640 above a Dock.
        precondition(height(800)+titleBar <= 800 && height(556)+titleBar <= 556)
        // Never shorter than the smallest window whose pop-ups still work, whatever the screen.
        precondition(height(300) == WindowFit.smallest && height(0) == WindowFit.smallest)
        // Fractional room rounds down, so the window never reaches a point past the screen.
        precondition(height(717.6) == height(717))

        // Placing the window. The visible part of a 1147 × 745 screen: 717 tall, from y 0 to 717.
        let visible=CGRect(x:0,y:0,width:1147,height:717)
        let minimum=reporter+titleBar
        // The reporter's window: 828 tall, top under the menu bar, bottom off the screen.
        let overflowing=CGRect(x:0,y:717-828,width:1147,height:828)
        let fitted=WindowFit.fitted(overflowing,visible:visible,minimumFrame:minimum)
        precondition(fitted.height == 717 && fitted.minY == 0 && fitted.maxY == 717 && fitted.minX == 0 && fitted.width == 1147,"\(fitted)")
        // A window that fits stays exactly where it is (at its minimum it fills the height).
        let fitting=CGRect(x:200,y:0,width:600,height:minimum)
        precondition(WindowFit.fitted(fitting,visible:visible,minimumFrame:minimum) == fitting)
        let roomy=CGRect(x:300,y:120,width:700,height:900)
        precondition(WindowFit.fitted(roomy,visible:CGRect(x:0,y:0,width:1512,height:1100),minimumFrame:800+titleBar) == roomy)
        // One partly below the bottom edge (or behind a Dock) moves up, keeping its size.
        let low=CGRect(x:200,y:-50,width:600,height:minimum)
        precondition(WindowFit.fitted(low,visible:visible,minimumFrame:minimum) == CGRect(x:200,y:0,width:600,height:minimum))
        let lowOnBig=CGRect(x:200,y:-50,width:600,height:900)
        precondition(WindowFit.fitted(lowOnBig,visible:CGRect(x:0,y:0,width:1512,height:1100),minimumFrame:800+titleBar) == CGRect(x:200,y:0,width:600,height:900))
        // One reaching past the menu bar moves down.
        let high=CGRect(x:200,y:300,width:600,height:600)
        precondition(WindowFit.fitted(high,visible:visible,minimumFrame:minimum).maxY == 717)
        // Moved to a screen with room, a window shorter than the new minimum grows back to it.
        let big=CGRect(x:0,y:0,width:1512,height:950)
        let grown=WindowFit.fitted(CGRect(x:0,y:100,width:600,height:717),visible:big,minimumFrame:800+titleBar)
        precondition(grown.height == 800+titleBar && grown.maxY <= 950 && grown.minY >= 0,"\(grown)")
        // A screen shorter than the smallest window: the title bar stays below the menu bar.
        let tiny=CGRect(x:0,y:0,width:1024,height:400)
        let squeezed=WindowFit.fitted(CGRect(x:0,y:0,width:600,height:600),visible:tiny,minimumFrame:WindowFit.smallest+titleBar)
        precondition(squeezed.maxY == 400,"\(squeezed)")
        print("WindowFitTests passed (title bar \(titleBar), 1147 × 745 window \(reporter), pop-ups \(reporter-WindowFit.sheetMargin))")
    }
}
