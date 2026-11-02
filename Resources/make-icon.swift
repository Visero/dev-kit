import AppKit
let root=CommandLine.arguments[1]
let iconset=URL(fileURLWithPath:root).appendingPathComponent("DevKit.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=context
    let s=CGFloat(size)
    let shape=NSBezierPath(roundedRect:NSRect(x:s*0.08,y:s*0.08,width:s*0.84,height:s*0.84),xRadius:s*0.185,yRadius:s*0.185)
    NSGradient(starting:NSColor(calibratedRed:0.18,green:0.78,blue:0.73,alpha:1),ending:NSColor(calibratedRed:0.02,green:0.36,blue:0.48,alpha:1))!.draw(in:shape,angle:-65)
    NSColor.white.withAlphaComponent(0.4).setStroke();shape.lineWidth=s*0.012;shape.stroke()
    let text="{ }" as NSString
    let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedSystemFont(ofSize:s*0.43,weight:.medium),.foregroundColor:NSColor.white]
    let measured=text.size(withAttributes:attrs)
    text.draw(at:NSPoint(x:(s-measured.width)/2,y:(s-measured.height)/2+s*0.015),withAttributes:attrs)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name+".png"))
}

// Native Icon Composer layer: keep the original brace silhouette, without a baked tile.
let glyphSize = 1024
let glyph = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:glyphSize,pixelsHigh:glyphSize,
                            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                            colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:glyph)!
let glyphText = "{ }" as NSString
let glyphAttributes: [NSAttributedString.Key:Any] = [
    .font: NSFont.monospacedSystemFont(ofSize:440,weight:.medium),
    .foregroundColor: NSColor(calibratedRed:0.02,green:0.65,blue:0.67,alpha:1)
]
let measuredGlyph = glyphText.size(withAttributes:glyphAttributes)
glyphText.draw(at:NSPoint(x:(1024-measuredGlyph.width)/2,y:(1024-measuredGlyph.height)/2+15),withAttributes:glyphAttributes)
NSGraphicsContext.restoreGraphicsState()
try glyph.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root).appendingPathComponent("DevKit-glyph.png"))
