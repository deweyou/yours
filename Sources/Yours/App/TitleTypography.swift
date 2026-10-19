import CoreText
import OSLog
import SwiftUI

/// Presentation-only fonts for note identity; never applied to stored rich text.
enum TitleTypography {
    static let postScriptName = BundledSerifFont.mediumName
    static var isRegistered: Bool { BundledSerifFont.isRegistered }
    static var resourceBundle: Bundle { BundledSerifFont.resourceBundle }

    static var document: Font {
        guard isRegistered else { return .system(size: DocumentTypography.titleSize, weight: .black) }
        return .custom(BundledSerifFont.heavyName, fixedSize: DocumentTypography.titleSize)
    }

    static func card(in context: Font.Context) -> Font {
        guard isRegistered else { return .headline }
        // Resolve the platform's semantic size first, including Dynamic Type.
        // Both the SwiftUI card and Core Text height measurement use this font.
        let size = CTFontGetSize(Font.headline.resolve(in: context).ctFont)
        return .custom(postScriptName, fixedSize: size)
    }

}

/// Bundled document faces are registered only in this process, never installed system-wide.
enum BundledSerifFont {
    static let extraLightName = "SourceHanSerifCN-ExtraLight"
    static let lightName = "SourceHanSerifCN-Light"
    static let mediumName = "SourceHanSerifCN-Medium"
    static let semiboldName = "SourceHanSerifCN-SemiBold"
    static let heavyName = "SourceHanSerifCN-Heavy"
    static let regularName = "SourceHanSerifCN-Regular"
    static let boldName = "SourceHanSerifCN-Bold"

    static let allNames = [extraLightName, lightName, regularName, mediumName, semiboldName, boldName, heavyName]

    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
            Bundle.module
        #else
            Bundle.main
        #endif
    }

    // Swift initializes this once, including standalone previews and package tests.
    // Process scope avoids installing or modifying the user's system fonts.
    static let isRegistered: Bool = {
        let logger = Logger(subsystem: "app.yours.editor", category: "BundledSerifFont")
        for name in allNames {
            guard let url = resourceBundle.url(forResource: name, withExtension: "otf", subdirectory: "Fonts") else {
                logger.error("Bundled document font is missing; using the system font.")
                return false
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }
            if let error = error?.takeRetainedValue() {
                if CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { continue }
                logger.error("Cannot register bundled document font: \(String(describing: error), privacy: .public)")
            } else {
                logger.error("Cannot register bundled document font; using the system font.")
            }
            return false
        }
        return true
    }()
}
