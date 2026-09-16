import AppKit
let root = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size:NSSize(width:size,height:size))
image.lockFocus()
NSColor.clear.setFill(); NSRect(x:0,y:0,width:size,height:size).fill()
let outline = NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:205,yRadius:205)
NSColor(calibratedWhite:0.025,alpha:1).setFill(); outline.fill()
let lime = NSColor(calibratedRed:199/255,green:1,blue:46/255,alpha:1)
lime.setStroke(); outline.lineWidth = 25; outline.stroke()
let text = "MMM" as NSString
let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:280,weight:.black),.foregroundColor:lime,.kern:0]
let textSize=text.size(withAttributes:attrs)
text.draw(at:NSPoint(x:(1024-textSize.width)/2,y:(1024-textSize.height)/2+4),withAttributes:attrs)
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root))
