import Foundation
import CoreImage
import ImageIO

/// The QR of `text` as a PNG data URL: CoreImage's generator at correction level M, redrawn black
/// on white, `scale` px per module, a 4-module quiet zone, no smoothing. nil when it cannot encode.
func qrPNG(_ text: String, scale: Int = 8) -> (dataURL: String, modules: Int)? {
    guard !text.isEmpty, (1...32).contains(scale), let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage, let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: out.extent) else { return nil }
    // one byte per generator pixel, top row first (a bitmap context's memory order)
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 255, count: w * h)
    let read = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard read else { return nil }
    // the generator's own margin is not the standard one: crop to the symbol, whose finder patterns mark three corners
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h { for x in 0..<w where px[y * w + x] < 128 { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) } }
    let n = x1 - x0 + 1
    guard n >= 21, n == y1 - y0 + 1, (n - 21) % 4 == 0 else { return nil }
    let quiet = 4, size = (n + 2 * quiet) * scale
    var img = [UInt8](repeating: 255, count: size * size)
    for r in 0..<n { for c in 0..<n where px[(y0 + r) * w + x0 + c] < 128 {
        for dy in 0..<scale { let row = ((r + quiet) * scale + dy) * size + (c + quiet) * scale; for dx in 0..<scale { img[row + dx] = 0 } }
    } }
    guard let provider = CGDataProvider(data: Data(img) as CFData),
          let bw = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
    let png = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(png as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, bw, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return ("data:image/png;base64," + (png as Data).base64EncodedString(), n + 2 * quiet)
}
