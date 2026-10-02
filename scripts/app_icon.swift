// Package the owner's square PNG into the standard macOS icon representations.
// macOS 26 draws app icons in its rounded-square shape and sets any other
// shape on a gray tile. The artwork, unchanged, fills that shape on Apple's
// icon grid: an 824-point body in a 1024-point canvas, continuous corners,
// transparent margin. The artwork's opaque square (inside any transparent
// shadow margin) maps onto the body over white, so the shape is always solid.
import AppKit
import SwiftUI
let source=URL(fileURLWithPath:CommandLine.arguments[1])
let directory=URL(fileURLWithPath:CommandLine.arguments[2])
guard let bitmap=NSBitmapImageRep(data:try Data(contentsOf:source)),
      bitmap.pixelsWide == bitmap.pixelsHigh, bitmap.pixelsWide >= 1024 else {
    fatalError("App artwork must be a square PNG at least 1024 pixels wide")
}
// The artwork's own rounded square: first mostly opaque pixel along the middle
// row and column (2 more pixels skip its anti-aliased edge).
let side=bitmap.pixelsWide
func opaque(_ x:Int, _ y:Int) -> Bool { (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0) >= 0.5 }
let left=(0..<side/2).first { opaque($0,side/2) } ?? 0, top=(0..<side/2).first { opaque(side/2,$0) } ?? 0
let right=(side/2..<side).reversed().first { opaque($0,side/2) } ?? side-1, bottom=(side/2..<side).reversed().first { opaque(side/2,$0) } ?? side-1
let square=NSRect(x:CGFloat(left+2),y:CGFloat(side-1-bottom+2),width:CGFloat(right-left-3),height:CGFloat(bottom-top-3))
let artwork=NSImage(size:NSSize(width:side,height:side))
artwork.addRepresentation(bitmap)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let output=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,
                                   bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                                   colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:output)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.imageInterpolation = .high
        let canvas=CGFloat(pixels), bodySide=canvas*824/1024
        let body=CGRect(x:(canvas-bodySide)/2,y:(canvas-bodySide)/2,width:bodySide,height:bodySide)
        context.cgContext.addPath(RoundedRectangle(cornerRadius:bodySide*185.4/824,style:.continuous).path(in:body).cgPath)
        context.cgContext.clip()
        NSColor.white.setFill();body.fill()
        artwork.draw(in:body,from:square,operation:.sourceOver,fraction:1)
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        try output.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x":"").png"))
    }
}
