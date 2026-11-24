import AppKit
import SwiftUI

/// Tokens measured from Dishylink src/index.css (MIT, (c) 2026 daveyhert).
enum Theme {
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    static let page = dynamic(dark: 0x000000, light: 0xf4f3ee)
    static let surface = dynamic(dark: 0x0c0c0c, light: 0xffffff)
    static let surfaceRaised = dynamic(dark: 0x1e1e1e, light: 0xffffff)
    static let ink = dynamic(dark: 0xffffff, light: 0x111110)
    static let inkSecondary = dynamic(dark: 0xb9b9b9, light: 0x55544f)
    static let inkMuted = dynamic(dark: 0x7c7c7c, light: 0x8a8880)
    static let hairline = dynamic(dark: 0x232323, light: 0xe7e5dc)
    static let gridDot = dynamic(dark: 0x161616, light: 0xdedcd2)
    static let down = dynamic(dark: 0x5b9bff, light: 0x2f6fed)
    static let up = dynamic(dark: 0x4ade80, light: 0x1ba85f)
    static let accent = dynamic(dark: 0xe0a422, light: 0xb7791f)
    static let good = dynamic(dark: 0x4db450, light: 0x16a34a)
    static let critical = dynamic(dark: 0xf43f5e, light: 0xe11d48)
    static let warm = dynamic(dark: 0xf09048, light: 0xd1671f)
    static let skyClear = dynamic(dark: 0xffffff, light: 0x111110)
    static let skyPartial = dynamic(dark: 0x6e0f0f, light: 0xefa09b)
    static let skyObstructed = dynamic(dark: 0xf51e1e, light: 0xd81b1b)
    static let skyUnmapped = dynamic(dark: 0x7c7c7c, light: 0x8a8880)

    // PostScript names of the bundled OFL fonts. D-DIN (Datto, a DIN 1451 design) is the free face closest to
    // the DIN lettering of the Starlink app; it ships in two weights, so medium reads as regular and semibold as bold.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .semibold, .bold, .heavy, .black: .custom("D-DIN-Bold", size: size)
        default: .custom("D-DIN", size: size)
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium", size: size)
    }

    static func registerFonts() {
        // The packaged app keeps resources in Contents/Resources; SwiftPM's Bundle.module only
        // finds them next to the .app or in this checkout's .build, so it is the `swift run` fallback.
        guard let folder = Bundle.main.url(forResource: "Fonts", withExtension: nil)
                ?? Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["ttf", "otf"].contains(file.pathExtension) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// The dashboard backdrop: Dishylink's 26px dot grid on the page colour.
struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 26
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(Theme.gridDot))
                }
            }
        }
        .background(Theme.page)
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    @MainActor func apply() {
        switch self {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }
}
