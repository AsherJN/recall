// Replace the generated AppIcon.icns with the owner's final artwork at build time.
import AppKit
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let image=NSImage(size:NSSize(width:pixels,height:pixels))
        image.lockFocus()
        NSColor(calibratedRed:0.10,green:0.13,blue:0.19,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:0,y:0,width:pixels,height:pixels),xRadius:CGFloat(pixels)*0.22,yRadius:CGFloat(pixels)*0.22).fill()
        let text="OW" as NSString
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:CGFloat(pixels)*0.32,weight:.bold),.foregroundColor:NSColor(calibratedRed:1,green:0.58,blue:0.18,alpha:1)]
        let bounds=text.size(withAttributes:attributes)
        text.draw(at:NSPoint(x:(CGFloat(pixels)-bounds.width)/2,y:(CGFloat(pixels)-bounds.height)/2),withAttributes:attributes)
        image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x":"").png"))
    }
}
