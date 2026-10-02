// Draws the disk image window's background at 1x and 2x: the app's cream
// ground, the Recall lockup, an arrow from the app to Applications and one line
// of instruction. Finder draws icon labels in black over a background picture in
// both appearances, so the ground stays light.
//
//   swift dmg_background.swift <Wordmark.png> <out.png> <app name> <width> <height> <app x> <applications x> <icon y>
// writes out.png and out@2x.png (dmgbuild combines them into one HiDPI TIFF).
import AppKit

let args=CommandLine.arguments
let wordmark=NSImage(contentsOf:URL(fileURLWithPath:args[1]))!
let output=URL(fileURLWithPath:args[2])
let name=args[3]
let width=CGFloat(Double(args[4])!), height=CGFloat(Double(args[5])!)
let appX=CGFloat(Double(args[6])!), applicationsX=CGFloat(Double(args[7])!), iconY=CGFloat(Double(args[8])!)
let ground=NSColor(srgbRed:0.975,green:0.970,blue:0.958,alpha:1)
let accent=NSColor(srgbRed:1,green:0.62,blue:0.10,alpha:1)
let ink=NSColor(srgbRed:0.15,green:0.13,blue:0.10,alpha:1)

for scale in [1,2] {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width)*scale,pixelsHigh:Int(height)*scale,bitsPerSample:8,
                             samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size=NSSize(width:width,height:height)
    NSGraphicsContext.saveGraphicsState()
    // Drawing uses top-left coordinates, like Finder's icon positions; the
    // context is marked flipped so text and images stay upright.
    let cg=NSGraphicsContext(bitmapImageRep:rep)!.cgContext
    cg.translateBy(x:0,y:height);cg.scaleBy(x:1,y:-1)
    let context=NSGraphicsContext(cgContext:cg,flipped:true)
    NSGraphicsContext.current=context
    context.imageInterpolation = .high
    ground.setFill();NSRect(x:0,y:0,width:width,height:height).fill()
    // The app's soft accent glow behind the lockup.
    let glow=NSGradient(colors:[accent.withAlphaComponent(0.13),accent.withAlphaComponent(0)])!
    glow.draw(fromCenter:NSPoint(x:width/2,y:60),radius:0,toCenter:NSPoint(x:width/2,y:60),radius:300,options:[])
    // Lockup, centered at the top. NSImage draws upright in a flipped context
    // only with respectFlipped.
    let markWidth:CGFloat=150, markHeight=markWidth*wordmark.size.height/wordmark.size.width
    wordmark.draw(in:NSRect(x:(width-markWidth)/2,y:34,width:markWidth,height:markHeight),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    // Arrow between the two icons (128-point icons; leave room around them).
    let start=appX+84, end=applicationsX-84
    let shaft=NSBezierPath();shaft.move(to:NSPoint(x:start,y:iconY));shaft.line(to:NSPoint(x:end-4,y:iconY))
    shaft.lineWidth=5;shaft.lineCapStyle = .round
    let head=NSBezierPath();head.move(to:NSPoint(x:end-16,y:iconY-13));head.line(to:NSPoint(x:end,y:iconY));head.line(to:NSPoint(x:end-16,y:iconY+13))
    head.lineWidth=5;head.lineCapStyle = .round;head.lineJoinStyle = .round
    accent.setStroke();shaft.stroke();head.stroke()
    // One line of instruction under the icon labels.
    let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
    let text=NSAttributedString(string:"Drag \(name) into Applications to install",attributes:[
        .font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:ink.withAlphaComponent(0.62),.paragraphStyle:paragraph])
    text.draw(in:NSRect(x:0,y:iconY+104,width:width,height:22))
    context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
    let file=scale == 1 ? output : output.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent+"@2x.png")
    try! rep.representation(using:.png,properties:[:])!.write(to:file)
}
