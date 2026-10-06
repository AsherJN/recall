import Foundation

// The fullscreen resolutions and the main-display rules Settings shows: shapes,
// sizes, which choices fit a display as Wine sees it, and what Overwatch uses when
// a choice is too large. The worker applies the same fit rule at launch
// (portable_preferences.h). Run from the repository root to also check the list
// against docs/candidate-parity-contract.json.
@main struct DisplayOptionsTests {
    static func r(_ width:Int,_ height:Int) -> DisplayResolution { DisplayResolution(width:width,height:height) }
    static func main() throws {
        let sizes=DisplayResolution.all.map { [$0.width,$0.height] }
        precondition(Set(sizes.map { "\($0[0])x\($0[1])" }) == ["1920x1200","2560x1600","3840x2400","1920x1080","2560x1440","3840x2160"])
        if let data=FileManager.default.contents(atPath:"docs/candidate-parity-contract.json"),
           let contract=try JSONSerialization.jsonObject(with:data) as? [String:Any] {
            let listed=(contract["supported_resolutions"] as! [[Int]]).map { "\($0[0])x\($0[1])" }
            precondition(Set(listed) == Set(sizes.map { "\($0[0])x\($0[1])" }),"the app and the contract offer different resolutions")
            precondition(contract["default_resolution"] as! [Int] == [DisplayResolution.standard.width,DisplayResolution.standard.height])
        }
        for option in DisplayResolution.all {
            precondition(DisplayResolution(shape:option.shape,size:option.size) == option)
            precondition(option.isSupported)
        }
        precondition(r(1920,1200).shape == .macBook && r(2560,1440).shape == .monitor && r(3840,2160).size == .ultra)
        precondition(!r(2560,1080).isSupported && !r(1920,1440).isSupported)

        // 14-inch MacBook Pro: 1512 x 982 points at 2x; fullscreen apps get 3024 x 1890 below the camera.
        let macBook=MainDisplay(name:"Built-in Retina Display",builtIn:true,points:CGSize(width:1512,height:982),pixels:CGSize(width:3024,height:1890))
        precondition(macBook.shape == .macBook && macBook.aspect == "16:10")
        precondition(macBook.fits(r(2560,1600)) && macBook.fits(r(2560,1440)) && !macBook.fits(r(3840,2160)) && !macBook.fits(r(3840,2400)))
        precondition(macBook.fitted(r(3840,2400)) == r(2560,1600) && macBook.fitted(r(3840,2160)) == r(2560,1440))
        precondition(macBook.fitted(r(1920,1200)) == r(1920,1200))
        // 13-inch MacBook Air: 1470 x 956 points.
        let air=MainDisplay(name:"Built-in",builtIn:true,points:CGSize(width:1470,height:956),pixels:CGSize(width:2940,height:1838))
        precondition(air.shape == .macBook && air.fits(r(2560,1600)) && !air.fits(r(3840,2400)))
        // A 1440p monitor at 1x (the owner's LG): Wine doubles it, so every size fits.
        let monitor=MainDisplay(name:"LG ULTRAGEAR",builtIn:false,points:CGSize(width:2560,height:1440),pixels:CGSize(width:2560,height:1440))
        precondition(monitor.shape == .monitor && monitor.aspect == "16:9" && monitor.size == "2560 × 1440")
        precondition(DisplayResolution.all.allSatisfy(monitor.fits))
        // A 4K monitor at its default 2x ("looks like 1920 x 1080").
        let uhd=MainDisplay(name:"4K",builtIn:false,points:CGSize(width:1920,height:1080),pixels:CGSize(width:3840,height:2160))
        precondition(uhd.fits(r(3840,2160)) && !uhd.fits(r(3840,2400)) && uhd.fitted(r(3840,2400)) == r(2560,1600))
        // Other shapes are named and treated as the nearer of the two.
        let wide=MainDisplay(name:"Ultrawide",builtIn:false,points:CGSize(width:3440,height:1440),pixels:CGSize(width:3440,height:1440))
        precondition(wide.aspect == "21:9" && wide.shape == .monitor)
        // Nothing fits a tiny display: the choice is kept (the worker does the same).
        let tiny=MainDisplay(name:"Tiny",builtIn:false,points:CGSize(width:800,height:500),pixels:CGSize(width:800,height:500))
        precondition(tiny.fitted(r(1920,1080)) == r(1920,1080))

        // A new installation, and Troubleshooting's reset: 1080p in the main display's shape.
        precondition(DisplayResolution.initial(for:macBook) == r(1920,1200) && DisplayResolution.initial(for:monitor) == r(1920,1080))
        precondition(DisplayResolution.initial(for:wide) == r(1920,1080) && DisplayResolution.initial(for:nil) == r(1920,1200))
        // Sizes chosen in Overwatch's Video settings: named, fitted and described like Settings' own.
        precondition(r(5120,2160).aspect == "21:9" && r(3440,1440).aspect == "21:9" && r(5120,1440).aspect == "32:9" && r(5120,2880).aspect == "16:9")
        // A player's 21:9 5K2K monitor ("looks like 2560 x 1080"): its own size fits and matches.
        let ultrawide=MainDisplay(name:"LG 5K2K",builtIn:false,points:CGSize(width:2560,height:1080),pixels:CGSize(width:5120,height:2160))
        precondition(ultrawide.aspect == "21:9" && ultrawide.fits(r(5120,2160)) && !ultrawide.fits(r(5120,2880)))
        precondition(ultrawide.caption(for:r(5120,2160)).hasPrefix("Matches your main display exactly"))
        precondition(ultrawide.caption(for:r(3840,2160)).hasPrefix("Your main display is wider than 16:9, so the picture has black bars at the sides."))
        precondition(ultrawide.caption(for:r(3440,1440)).hasPrefix("Scaled up to fill your main display."))
        precondition(ultrawide.fitted(r(5120,2880)) == r(3840,2160))
        // The same 21:9 size on a 16:9 monitor: bars above and below.
        precondition(uhd.caption(for:r(3440,1440)).hasPrefix("Your main display is taller than 21:9, so the picture has black bars above and below."))
        // Settings' sizes keep their wording.
        precondition(monitor.caption(for:r(1920,1200)).hasPrefix("Your main display is wider than 16:10, so the picture has black bars at the sides."))
        precondition(macBook.caption(for:r(1920,1080)).hasPrefix("Your main display is taller than 16:9, so the picture has black bars above and below."))
        precondition(macBook.caption(for:r(3840,2400)).hasPrefix("Too large for this main display: Overwatch uses 2560 × 1600"))
        precondition(macBook.caption(for:r(1920,1200)).hasPrefix("Scaled up to fill your main display."))
        precondition(monitor.caption(for:r(2560,1440)).hasPrefix("Matches your main display exactly"))
        precondition(monitor.caption(for:r(3840,2160)).hasPrefix("Larger than your main display"))
        // A 5K display at its default 2x: Overwatch lists 5120 x 2880.
        let fiveK=MainDisplay(name:"Studio Display",builtIn:false,points:CGSize(width:2560,height:1440),pixels:CGSize(width:5120,height:2880))
        precondition(fiveK.fits(r(5120,2880)) && fiveK.caption(for:r(5120,2880)).hasPrefix("Matches your main display exactly"))

        // Scaled modes (issue #9). The owner's LG ULTRAGEAR as macOS lists it: 2560 x 1440
        // native up to 144 Hz, its sharp 1280 x 720 twin, 1920 x 1080 at 1x, and 1920 x 1080
        // drawn at 3840 x 2160 at 50 Hz and below.
        func m(_ w:Int,_ h:Int,_ pw:Int,_ ph:Int,_ hz:Double,native:Bool=false) -> DisplayMode {
            DisplayMode(points:CGSize(width:w,height:h),pixels:CGSize(width:pw,height:ph),refresh:hz,native:native)
        }
        // The note keeps numbers and units on one line with no-break spaces.
        func plain(_ note:String?) -> String? { note?.replacingOccurrences(of:"\u{00A0}",with:" ") }
        let lgModes=[144.0,120,100,60].flatMap { [m(2560,1440,2560,1440,$0,native:true),m(1280,720,2560,1440,$0,native:true),m(1920,1080,1920,1080,$0)] } +
            [50.0,30].map { m(1920,1080,3840,2160,$0) }
        let lg=MainDisplay(name:"LG ULTRAGEAR",builtIn:false,points:CGSize(width:2560,height:1440),scale:1,refresh:144,modes:lgModes)
        precondition(lg.native == CGSize(width:2560,height:1440) && lg.pixels == lg.native && lg.scalingNote == nil)
        precondition(lg.caption(for:r(2560,1440)).hasPrefix("Matches your main display exactly"))
        // The player's setup: "1920 x 1080" drawn at 3840 x 2160 and shrunk to the 1440p screen.
        let scaled=MainDisplay(name:"LG ULTRAGEAR",builtIn:false,points:CGSize(width:1920,height:1080),scale:2,refresh:50,modes:lgModes)
        precondition(scaled.drawn == CGSize(width:3840,height:2160) && scaled.pixels == CGSize(width:2560,height:1440) && scaled.size == "2560 × 1440")
        precondition(plain(scaled.scalingNote) == "macOS is resizing everything on this monitor, so Overwatch looks softer than it should and runs at 50 Hz instead of 144 Hz. To fix it, close Overwatch and set this monitor to 2560 × 1440 at 144 Hz.")
        precondition(scaled.scalingNote!.contains("2560\u{00A0}×\u{00A0}1440 at 144\u{00A0}Hz."))
        // Settings no longer calls 3840 x 2160 an exact match there, and the fit rule is unchanged.
        precondition(scaled.caption(for:r(2560,1440)).hasPrefix("Matches your main display exactly"))
        precondition(scaled.caption(for:r(3840,2160)).hasPrefix("Larger than your main display"))
        precondition(scaled.fits(r(3840,2160)) && !scaled.fits(r(3840,2400)))
        // 1920 x 1080 at 1x on the same monitor: drawn smaller and stretched.
        let low=MainDisplay(name:"LG ULTRAGEAR",builtIn:false,points:CGSize(width:1920,height:1080),scale:1,refresh:144,modes:lgModes)
        precondition(plain(low.scalingNote) == "macOS is resizing everything on this monitor, so Overwatch looks softer than it should. To fix it, close Overwatch and set this monitor to 2560 × 1440.")
        // The sharp 1280 x 720 twin is drawn at the screen's pixels: no note.
        precondition(MainDisplay(name:"LG",builtIn:false,points:CGSize(width:1280,height:720),scale:2,refresh:144,modes:lgModes).scalingNote == nil)
        // A 4K monitor at "2560 x 1440" (drawn at 5120 x 2880): its sharp choice is 1920 x 1080.
        let uhdModes=[60.0].flatMap { [m(3840,2160,3840,2160,$0,native:true),m(1920,1080,3840,2160,$0,native:true),m(2560,1440,5120,2880,$0),m(1920,1080,1920,1080,$0)] }
        let uhdScaled=MainDisplay(name:"4K",builtIn:false,points:CGSize(width:2560,height:1440),scale:2,refresh:60,modes:uhdModes)
        precondition(plain(uhdScaled.scalingNote) == "macOS is resizing everything on this monitor, so Overwatch looks softer than it should. To fix it, close Overwatch and set this monitor to 1920 × 1080.")
        precondition(MainDisplay(name:"4K",builtIn:false,points:CGSize(width:1920,height:1080),scale:2,refresh:60,modes:uhdModes).scalingNote == nil)
        // A 4K TV at 1920 x 1080 1x: the sharp choice has the same name.
        let tv=MainDisplay(name:"TV",builtIn:false,points:CGSize(width:1920,height:1080),scale:1,refresh:60,modes:uhdModes)
        precondition(plain(tv.scalingNote)!.hasSuffix("set this monitor to 1920 × 1080, not the “low resolution” one."))
        // A 13-inch MacBook Air at its default, drawn 2940 x 1912 for a 2560 x 1664 screen: no
        // note, and the area below the camera is the screen's own 2560 x 1600.
        let airModes=[m(1470,956,2940,1912,60),m(1280,832,2560,1664,60,native:true),m(2560,1664,2560,1664,60,native:true)]
        let airDefault=MainDisplay(name:"Built-in",builtIn:true,points:CGSize(width:1470,height:956),scale:2,cameraInset:956.0*64/1664,refresh:60,modes:airModes)
        precondition(airDefault.scalingNote == nil && airDefault.pixels == CGSize(width:2560,height:1600))
        precondition(airDefault.caption(for:r(2560,1600)).hasPrefix("Matches your main display exactly"))
        // No native mode reported (a virtual or unusual display): today's behaviour, no note.
        let unknown=MainDisplay(name:"Virtual",builtIn:false,points:CGSize(width:1920,height:1080),scale:2,modes:[m(1920,1080,3840,2160,60)])
        precondition(unknown.native == nil && unknown.pixels == CGSize(width:3840,height:2160) && unknown.scalingNote == nil)

        if let main=MainDisplay.current {
            print("main display:",main.name,main.size,main.aspect,"drawn",main.drawn,"native",main.native as Any,"note",main.scalingNote ?? "none")
        }
        print("display options: all checks passed")
    }
}
