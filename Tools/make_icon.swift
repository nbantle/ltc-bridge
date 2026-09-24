// Draws the app icon and writes Resources/AppIcon.icns (run: swift Tools/make_icon.swift)
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.05, alpha: 1))!.draw(in: bg, angle: -90)
    // Biphase waveform
    let wave = NSBezierPath()
    let y0 = s * 0.60, amp = s * 0.09, x0 = rect.minX + s * 0.08, w = rect.width - s * 0.16
    let pattern: [Int] = [1, 0, 1, 1, 0, 1, 0, 0]
    var x = x0, level = true
    let step = w / CGFloat(pattern.count)
    wave.move(to: NSPoint(x: x, y: y0 + amp))
    for b in pattern {
        level.toggle(); wave.line(to: NSPoint(x: x, y: y0 + (level ? amp : -amp)))
        if b == 1 { x += step / 2; wave.line(to: NSPoint(x: x, y: y0 + (level ? amp : -amp))); level.toggle()
                    wave.line(to: NSPoint(x: x, y: y0 + (level ? amp : -amp))); x += step / 2 }
        else { x += step }
        wave.line(to: NSPoint(x: x, y: y0 + (level ? amp : -amp)))
    }
    wave.lineWidth = max(1, s * 0.025); wave.lineJoinStyle = .miter
    NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.45, alpha: 1).setStroke(); wave.stroke()
    let text = "MTC" as NSString
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.2, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let ts = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (s - ts.width) / 2, y: s * 0.22), withAttributes: attrs)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}
for px in sizes where px <= 512 {
    try! draw(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(px)x\(px).png"))
    try! draw(px * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(px)x\(px)@2x.png"))
}
