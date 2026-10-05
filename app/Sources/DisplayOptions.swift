import AppKit

/// A fullscreen resolution Overwatch uses. Settings offers six (docs/candidate-parity-contract.json):
/// 1080p, 1440p and 4K, each in the shape of MacBook screens (16:10) or of monitors
/// and TVs (16:9); the player can also choose another in Overwatch's Video settings,
/// such as an ultrawide monitor's own size, and Recall keeps it. The window driver
/// shows the game's image on any display, scaled to fit, without changing the
/// display's own resolution.
struct DisplayResolution:Hashable {
    enum Shape:CaseIterable { case macBook, monitor }
    enum Size:CaseIterable { case standard, high, ultra }
    let width:Int
    let height:Int
    static let standard=DisplayResolution(width:1920,height:1200)
    static let all=Shape.allCases.flatMap { shape in Size.allCases.map { DisplayResolution(shape:shape,size:$0) } }
    init(width:Int, height:Int) { self.width=width;self.height=height }
    init(shape:Shape, size:Size) {
        let width=[Size.standard:1920,.high:2560,.ultra:3840][size]!
        self.init(width:width,height:shape == .macBook ? width*10/16 : width*9/16)
    }
    var shape:Shape { width*10 == height*16 ? .macBook : .monitor }
    var size:Size { width >= 3840 ? .ultra : width >= 2560 ? .high : .standard }
    var label:String { "\(width) × \(height)" }
    var isSupported:Bool { DisplayResolution.all.contains(self) }
    var ratio:CGFloat { CGFloat(width)/CGFloat(max(height,1)) }
    var aspect:String { DisplayResolution.aspectName(ratio) }
    /// The nearest common name for a width-to-height ratio.
    static func aspectName(_ ratio:CGFloat) -> String {
        let known:[(String,CGFloat)]=[("16:10",1.6),("16:9",16.0/9),("21:9",2.37),("32:9",32.0/9),("3:2",1.5),("4:3",4.0/3),("5:4",1.25)]
        return known.min { abs($0.1-ratio) < abs($1.1-ratio) }!.0
    }
    /// Where a new installation starts, and where Troubleshooting's reset returns:
    /// 1080p in the main display's shape, the fastest of Settings' sizes.
    static func initial(for main:MainDisplay?) -> DisplayResolution {
        main?.shape == .monitor ? DisplayResolution(shape:.monitor,size:.standard) : .standard
    }
}

/// The main display (the one with the menu bar), where Overwatch opens.
struct MainDisplay:Equatable {
    let name:String
    let builtIn:Bool
    /// The whole screen in points, as Wine sees it at twice the size (Retina mode).
    let points:CGSize
    /// The pixels fullscreen apps get: below the camera housing on MacBooks with one.
    let pixels:CGSize
    static var current:MainDisplay? { NSScreen.screens.first.map(MainDisplay.init) }
    init(_ screen:NSScreen) {
        let scale=screen.backingScaleFactor
        let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        name=screen.localizedName
        builtIn=CGDisplayIsBuiltin(id) != 0
        points=screen.frame.size
        pixels=CGSize(width:(screen.frame.width*scale).rounded(),height:((screen.frame.height-screen.safeAreaInsets.top)*scale).rounded())
    }
    init(name:String, builtIn:Bool, points:CGSize, pixels:CGSize) {
        self.name=name;self.builtIn=builtIn;self.points=points;self.pixels=pixels
    }
    var shape:DisplayResolution.Shape { pixels.width/max(pixels.height,1) < 1.69 ? .macBook : .monitor }
    var aspect:String { DisplayResolution.aspectName(pixels.width/max(pixels.height,1)) }
    var size:String { "\(Int(pixels.width)) × \(Int(pixels.height))" }
    /// The game's window has to fit inside the display as Wine sees it, or the pointer
    /// can't reach all of it. The worker applies the same rule when Overwatch opens.
    func fits(_ resolution:DisplayResolution) -> Bool {
        CGFloat(resolution.width) <= points.width*2 && CGFloat(resolution.height) <= points.height*2
    }
    /// What Overwatch uses on this display for a choice: the choice if it fits, else the
    /// largest that fits in the same shape, else the largest that fits at all.
    func fitted(_ resolution:DisplayResolution) -> DisplayResolution {
        guard !fits(resolution) else { return resolution }
        let fitting=DisplayResolution.all.filter(fits)
        let largest={ (options:[DisplayResolution]) in options.max { $0.width*$0.height < $1.width*$1.height } }
        return largest(fitting.filter { $0.shape == resolution.shape }) ?? largest(fitting) ?? resolution
    }
    /// What the player sees with a resolution on this display, for Settings.
    func caption(for choice:DisplayResolution) -> String {
        let sharper="Larger sizes look sharper and lower your frame rate."
        if !fits(choice) {
            return "Too large for this main display: Overwatch uses \(fitted(choice).label) until a larger display is your main display."
        }
        // Shapes within 2% look the same (a MacBook's area below the camera is 16:10).
        let screen=pixels.width/max(pixels.height,1)
        if choice.ratio < screen*0.98 {
            return "Your main display is wider than \(choice.aspect), so the picture has black bars at the sides. \(sharper)"
        }
        if choice.ratio > screen*1.02 {
            return "Your main display is taller than \(choice.aspect), so the picture has black bars above and below. \(sharper)"
        }
        if CGFloat(choice.width) == pixels.width && CGFloat(choice.height) == pixels.height {
            return "Matches your main display exactly: the sharpest picture. Smaller sizes run faster."
        }
        if CGFloat(choice.width) > pixels.width {
            return "Larger than your main display: smoother edges, but a much lower frame rate."
        }
        return "Scaled up to fill your main display. \(sharper)"
    }
}
