// Draws the StarPulse app icon (original artwork) and writes an .iconset for iconutil.
// Usage: swift scripts/make-icon.swift <output.iconset>
// Layout follows the macOS icon grid: 1024 px canvas, 824 px rounded body with a 185 px corner radius.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    let detailed = pixels >= 128

    // Body: near-black, lit slightly from the top.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x1e1e1e), ending: color(0x000000))!.draw(in: body, angle: -90)
    body.addClip()

    let center = CGPoint(x: 512, y: 370), radius: CGFloat = 292
    // Ground plane.
    color(0x1a1a1a).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 360, y: center.y - 70, width: 720, height: 140)).fill()

    if detailed {
        // Dome of dots: a hemisphere seen slightly from above, back dots dimmer than front ones.
        for elevation in stride(from: 4.0, through: 84.0, by: 8.0) {
            let ring = cos(elevation * .pi / 180), lift = sin(elevation * .pi / 180)
            let count = max(6, Int(46 * ring))
            for step in 0..<count {
                let azimuth = Double(step) / Double(count) * 2 * .pi
                let x = center.x + radius * CGFloat(ring * sin(azimuth))
                let depth = cos(azimuth) // 1 = far side
                let y = center.y + radius * CGFloat(lift) + radius * 0.22 * CGFloat(ring * depth)
                let front = depth < 0
                // A band of red on the low western sky reads as "obstruction" without a word.
                let obstructed = elevation < 30 && azimuth > 3.6 && azimuth < 4.9
                let dot: CGFloat = front ? 13 : 9
                (obstructed ? color(0xf51e1e, front ? 1 : 0.7) : color(0xffffff, front ? 0.95 : 0.4)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
            }
        }
        // The dish: a white slab facing the sky.
        let dish = NSBezierPath()
        dish.move(to: CGPoint(x: 432, y: 392)); dish.line(to: CGPoint(x: 560, y: 432))
        dish.line(to: CGPoint(x: 600, y: 380)); dish.line(to: CGPoint(x: 470, y: 342)); dish.close()
        color(0xf2f2f2).setFill(); dish.fill()
    } else {
        // Small sizes: a solid dome outline keeps the shape legible.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 180)
        arc.lineWidth = 64; arc.lineCapStyle = .round
        color(0xffffff).setStroke(); arc.stroke()
    }

    // Beam and satellite in the app's gold accent.
    let satellite = CGPoint(x: 742, y: 772)
    let beam = NSBezierPath()
    beam.move(to: CGPoint(x: 516, y: 398)); beam.line(to: satellite)
    beam.lineWidth = detailed ? 14 : 40; beam.lineCapStyle = .round
    color(0xe0a422).setStroke(); beam.stroke()
    if detailed {
        let glow = NSGradient(starting: color(0xe0a422, 0.55), ending: color(0xe0a422, 0))!
        glow.draw(fromCenter: satellite, radius: 0, toCenter: satellite, radius: 120, options: [])
    }
    let dot: CGFloat = detailed ? 70 : 150
    color(0xe0a422).setFill()
    NSBezierPath(ovalIn: NSRect(x: satellite.x - dot / 2, y: satellite.y - dot / 2, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let data = draw(pixels: points * scale).representation(using: .png, properties: [:])!
    try! data.write(to: output.appending(path: name))
}
print("wrote", output.path)
