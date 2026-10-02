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
        if let main=MainDisplay.current { print("main display:",main.name,main.size,main.aspect) }
        print("display options: all checks passed")
    }
}
