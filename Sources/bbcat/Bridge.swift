import AppKit
import ImageIO
import UniformTypeIdentifiers

enum bbcatError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }

    static func last(_ fallback: String) -> bbcatError {
        guard let pointer = bbcat_take_last_error() else { return .message(fallback) }
        defer { bbcat_string_free(pointer) }
        return .message(String(cString: pointer))
    }
}

enum bbcatWelcome {
    static func image(scale: Int) throws -> NSImage {
        var frame = BbcatFrame(data: nil, length: 0, duration_ns: 0)
        guard bbcat_render_welcome(scale, &frame) != 0, let bytes = frame.data else {
            throw bbcatError.last("Could not render the welcome artwork")
        }
        defer { bbcat_bytes_free(bytes, frame.length) }
        let data = Data(bytes: bytes, count: frame.length)
        guard let image = NSImage(data: data) else {
            throw bbcatError.message("The renderer returned an invalid welcome image")
        }
        return image
    }
}

struct bbcatDocumentInfo {
    let format: String
    let columns: Int
    let rows: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let glyphWidth: Int
    let glyphHeight: Int
    let raster: Bool
    let supportsUTF8: Bool
    let embeddedFont: Bool
    let trueColor: Bool
    let hasSauce: Bool
    let sauceUsesICEColors: Bool
    let sauceLetterSpacing: Int?
    let title: String?
    let author: String?
    let group: String?
    let date: String?
    let fontName: String?
}

final class bbcatDocument {
    private let handle: OpaquePointer
    let sourceURL: URL
    let frameCount: Int
    let isAnimated: Bool
    let displayTitle: String
    let info: bbcatDocumentInfo

    /// Whether the artwork is VGA 8x16 text, so the 9px font and legacy aspect
    /// options apply. False for raster formats and non-VGA fonts.
    private(set) lazy var hasVGAText = bbcat_document_has_vga_text(handle) != 0

    /// What the file's SAUCE record asks for, or nil when it doesn't say. These
    /// only seed the View options when the file opens; the options decide.
    private(set) lazy var sauceSuggestsNinePixelFont: Bool? = sauceDisplayHints().letterSpacing
    private(set) lazy var sauceSuggestsLegacyAspect: Bool? = sauceDisplayHints().legacyAspect

    private func sauceDisplayHints() -> (letterSpacing: Bool?, legacyAspect: Bool?) {
        var spacing: Int32 = 0, aspect: Int32 = -1
        bbcat_document_sauce_display_hints(handle, &spacing, &aspect)
        return (spacing == 0 ? nil : spacing == 9, aspect < 0 ? nil : aspect == 1)
    }

    /// Whether character cells are 9 pixels wide, as VGA text mode draws them.
    private(set) var usesNinePixelFont = false

    /// Whether rows are stretched to the pixel shape of a 4:3 CRT.
    var emulatesLegacyAspect = false

    /// 80x25 VGA text filled a 4:3 screen, so a cell is 2.4 times taller than
    /// it is wide. With 16-pixel rows that is 720x400 pixels (9px cells) drawn
    /// 1.35 times taller, or 640x400 (8px cells) drawn 1.2 times taller.
    private var verticalStretch: CGFloat {
        guard emulatesLegacyAspect, hasVGAText else { return 1 }
        return usesNinePixelFont ? 1.35 : 1.2
    }

    init(url: URL) throws {
        guard let handle = url.path.withCString({ bbcat_document_open($0) }) else {
            throw bbcatError.last("Could not decode the file")
        }
        self.handle = handle
        sourceURL = url
        frameCount = Int(bbcat_document_frame_count(handle))
        isAnimated = bbcat_document_is_animated(handle) != 0
        info = try Self.copyInfo(from: handle)
        let fallback = url.lastPathComponent.isEmpty ? "ANSI art" : url.lastPathComponent
        displayTitle = fallback.withCString { fallbackPointer in
            guard let title = bbcat_document_display_title(handle, fallbackPointer) else { return fallback }
            defer { bbcat_string_free(title) }
            return String(cString: title)
        }
    }

    deinit { bbcat_document_free(handle) }

    /// Switches between 8- and 9-pixel cells; it applies only to VGA text artwork.
    func setNinePixelFont(_ enabled: Bool) {
        usesNinePixelFont = bbcat_document_set_nine_pixel_font(handle, enabled ? 1 : 0) != 0
    }

    func supports(scale: Int) -> Bool {
        scale > 0 && bbcat_document_supports_scale(handle, scale) != 0
    }

    func frame(at index: Int, scale: Int) throws -> (image: NSImage, duration: TimeInterval) {
        var frame = BbcatFrame(data: nil, length: 0, duration_ns: 0)
        guard bbcat_document_render_frame(handle, index, scale, &frame) != 0,
              let bytes = frame.data else {
            throw bbcatError.last("Could not render the artwork")
        }
        defer { bbcat_bytes_free(bytes, frame.length) }
        let data = Data(bytes: bytes, count: frame.length)
        guard let image = NSImage(data: data) else {
            throw bbcatError.message("The renderer returned an invalid image")
        }
        // Stretch at display time: the view draws with nearest-neighbour scaling.
        image.size.height = (image.size.height * verticalStretch).rounded()
        return (image, TimeInterval(frame.duration_ns) / 1_000_000_000)
    }

    func export(scale: Int) throws -> Data {
        guard verticalStretch != 1 else { return try nativeExport(scale: scale) }
        let type = isAnimated ? UTType.gif : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, isAnimated ? frameCount : 1, nil
        ) else { throw bbcatError.message("Could not create the export file") }
        if isAnimated {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
        }
        for index in 0..<(isAnimated ? frameCount : 1) {
            let (image, duration) = try frame(at: index, scale: scale)
            let properties: [CFString: Any] = isAnimated
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(duration, 0.01)]]
                : [:]
            CGImageDestinationAddImage(destination, try Self.stretchedBitmap(image), properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw bbcatError.message("Could not export the artwork")
        }
        return output as Data
    }

    /// Bakes an image's (stretched) display size into its pixels, without smoothing.
    private static func stretchedBitmap(_ image: NSImage) throws -> CGImage {
        let width = Int(image.size.width), height = Int(image.size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw bbcatError.message("Could not export the artwork")
        }
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let stretched = context.makeImage() else {
            throw bbcatError.message("Could not export the artwork")
        }
        return stretched
    }

    private func nativeExport(scale: Int) throws -> Data {
        var output = BbcatFrame(data: nil, length: 0, duration_ns: 0)
        let succeeded = isAnimated
            ? bbcat_document_encode_gif(handle, scale, &output)
            : bbcat_document_encode_png(handle, scale, &output)
        guard succeeded != 0, let bytes = output.data else {
            throw bbcatError.last("Could not export the artwork")
        }
        defer { bbcat_bytes_free(bytes, output.length) }
        return Data(bytes: bytes, count: output.length)
    }

    private static func copyInfo(from handle: OpaquePointer) throws -> bbcatDocumentInfo {
        var raw = BbcatDocumentInfo()
        guard bbcat_document_copy_info(handle, &raw) != 0 else {
            bbcat_document_free(handle)
            throw bbcatError.last("Could not inspect the artwork")
        }

        func string(_ field: Int32) -> String? {
            guard let pointer = bbcat_document_copy_metadata_string(handle, field) else { return nil }
            defer { bbcat_string_free(pointer) }
            return String(cString: pointer)
        }

        return bbcatDocumentInfo(
            format: string(Int32(BBCAT_METADATA_FORMAT)) ?? "Unknown",
            columns: Int(raw.columns),
            rows: Int(raw.rows),
            pixelWidth: raw.has_pixel_dimensions != 0 ? Int(raw.pixel_width) : nil,
            pixelHeight: raw.has_pixel_dimensions != 0 ? Int(raw.pixel_height) : nil,
            glyphWidth: Int(raw.glyph_width),
            glyphHeight: Int(raw.glyph_height),
            raster: raw.raster != 0,
            supportsUTF8: raw.utf8_supported != 0,
            embeddedFont: raw.embedded_font != 0,
            trueColor: raw.true_color != 0,
            hasSauce: raw.has_sauce != 0,
            sauceUsesICEColors: raw.sauce_ice_colors != 0,
            sauceLetterSpacing: raw.sauce_letter_spacing == 0 ? nil : Int(raw.sauce_letter_spacing),
            title: string(Int32(BBCAT_METADATA_TITLE)),
            author: string(Int32(BBCAT_METADATA_AUTHOR)),
            group: string(Int32(BBCAT_METADATA_GROUP)),
            date: string(Int32(BBCAT_METADATA_DATE)),
            fontName: string(Int32(BBCAT_METADATA_FONT_NAME))
        )
    }
}
