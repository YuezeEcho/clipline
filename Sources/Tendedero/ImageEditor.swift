import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Coordinates are original image pixels, measured from its top-left corner.
/// Undo holds vectors and crop rectangles, never a full bitmap per brush stroke.
enum ImageEditTool: String, CaseIterable, Identifiable {
    case brush, highlighter, arrow, rectangle, ellipse, text, mosaic, cover, eraser, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: return C("Brush", "画笔", "畫筆")
        case .highlighter: return C("Highlighter", "荧光笔", "螢光筆")
        case .mosaic: return C("Mosaic", "马赛克", "馬賽克")
        case .eraser: return C("Eraser", "橡皮擦", "橡皮擦")
        case .arrow: return C("Arrow", "箭头", "箭頭")
        case .rectangle: return C("Rectangle", "框线", "框線")
        case .ellipse: return C("Ellipse", "椭圆", "橢圓")
        case .cover: return C("Cover", "遮盖", "遮蓋")
        case .text: return C("Text", "文字", "文字")
        case .crop: return C("Crop", "裁切", "裁切")
        }
    }
    var symbol: String {
        switch self {
        case .brush: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "square.grid.3x3.fill"
        case .eraser: return "eraser"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .cover: return "rectangle.fill"
        case .text: return "textformat"
        case .crop: return "crop"
        }
    }
}

struct ImageAnnotation {
    let tool: ImageEditTool
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    var text = ""
    var fontSize: CGFloat = 32
    var mosaicImage: CGImage?

    func draw() {
        guard let first = points.first else { return }
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch tool {
        case .brush, .highlighter:
            if tool == .highlighter { color.withAlphaComponent(0.32).setFill() }
            if points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                           width: width, height: width)).fill()
                return
            }
            if tool == .highlighter {
                color.withAlphaComponent(0.32).setStroke()
                path.lineCapStyle = .butt
            }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        case .arrow:
            guard let last = points.last, hypot(last.x - first.x, last.y - first.y) > 1 else { return }
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(hypot(last.x - first.x, last.y - first.y) * 0.45, max(16, width * 4))
            for turn in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: last)
                path.line(to: CGPoint(x: last.x - head * cos(angle + turn), y: last.y - head * sin(angle + turn)))
            }
        case .rectangle:
            guard let last = points.last else { return }
            path.appendRect(Self.rectangle(first, last))
        case .ellipse:
            guard let last = points.last else { return }
            path.appendOval(in: Self.rectangle(first, last))
        case .cover:
            guard let last = points.last else { return }
            Self.rectangle(first, last).fill()
            return
        case .text:
            (text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color
            ])
            return
        case .mosaic:
            guard let last = points.last else { return }
            let rect = Self.rectangle(first, last)
            if let mosaicImage {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: mosaicImage, size: rect.size).draw(in: rect, from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.systemGray.withAlphaComponent(0.4).setFill()
                rect.fill()
            }
            return
        case .crop, .eraser: return
        }
        path.stroke()
    }

    static func rectangle(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Presets operate in the visible orientation. Pixel presets never upscale.
enum ImageCropPreset: Equatable {
    case ratio(Int, Int), pixels(Int, Int)
    static let ratios: [ImageCropPreset] = [.ratio(1, 1), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9), .ratio(9, 16)]
    static let sizes: [ImageCropPreset] = [.pixels(640, 480), .pixels(1280, 720), .pixels(1920, 1080), .pixels(1080, 1080), .pixels(1080, 1920)]
    var title: String {
        switch self {
        case let .ratio(w, h): return "\(w):\(h)"
        case let .pixels(w, h): return "\(w) × \(h) px"
        }
    }
    var aspectRatio: CGFloat? {
        if case let .ratio(w, h) = self { return CGFloat(w) / CGFloat(h) }
        return nil
    }
    var isFixedSize: Bool { if case .pixels = self { return true }; return false }
    func frame(in size: CGSize) -> CGRect? {
        var width: CGFloat, height: CGFloat
        switch self {
        case let .ratio(w, h):
            let ratio = CGFloat(w) / CGFloat(h)
            width = min(size.width, size.height * ratio)
            height = width / ratio
        case let .pixels(w, h):
            width = CGFloat(w); height = CGFloat(h)
            guard width <= size.width, height <= size.height else { return nil }
        }
        width = floor(width); height = floor(height)
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: floor((size.width - width) / 2), y: floor((size.height - height) / 2), width: width, height: height)
    }
}

/// Crop gestures run in visible pixels, including after rotations and flips.
/// They only change a preview frame; applying is a separate document operation.
enum ImageCropHandle: CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft
    var signs: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -1, y: -1)
        case .topRight: return CGPoint(x: 1, y: -1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottomLeft: return CGPoint(x: -1, y: 1)
        }
    }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: signs.x < 0 ? rect.minX : rect.maxX, y: signs.y < 0 ? rect.minY : rect.maxY)
    }
}

enum ImageCropFrame {
    static func moved(_ rect: CGRect, by delta: CGPoint, in size: CGSize) -> CGRect {
        CGRect(x: min(max(0, (rect.minX + delta.x).rounded()), max(0, size.width - rect.width)),
               y: min(max(0, (rect.minY + delta.y).rounded()), max(0, size.height - rect.height)),
               width: rect.width, height: rect.height)
    }
    static func resized(_ rect: CGRect, handle: ImageCropHandle, by delta: CGPoint,
                        in size: CGSize, ratio: CGFloat?) -> CGRect {
        let signs = handle.signs
        let corner = handle.point(in: rect)
        let anchor = CGPoint(x: signs.x < 0 ? rect.maxX : rect.minX,
                             y: signs.y < 0 ? rect.maxY : rect.minY)
        return anchored(at: anchor, toward: CGPoint(x: corner.x + delta.x, y: corner.y + delta.y),
                        signs: signs, in: size, ratio: ratio, useVertical: abs(delta.y) * (ratio ?? 1) > abs(delta.x))
    }
    static func created(from anchor: CGPoint, to point: CGPoint, in size: CGSize, ratio: CGFloat?) -> CGRect {
        let signs = CGPoint(x: point.x < anchor.x ? -1 : 1, y: point.y < anchor.y ? -1 : 1)
        return anchored(at: anchor, toward: point, signs: signs, in: size, ratio: ratio,
                        useVertical: abs(point.y - anchor.y) * (ratio ?? 1) > abs(point.x - anchor.x))
    }
    private static func anchored(at anchor: CGPoint, toward point: CGPoint, signs: CGPoint,
                                 in size: CGSize, ratio: CGFloat?, useVertical: Bool) -> CGRect {
        let maxW = signs.x < 0 ? anchor.x : size.width - anchor.x
        let maxH = signs.y < 0 ? anchor.y : size.height - anchor.y
        var width = min(maxW, max(2, (point.x - anchor.x) * signs.x))
        var height = min(maxH, max(2, (point.y - anchor.y) * signs.y))
        if let ratio {
            // Choose the dimension the user actually dragged, so shrinking works.
            width = min(min(maxW, maxH * ratio), max(max(2, 2 * ratio), useVertical ? height * ratio : width))
            height = width / ratio
        }
        return CGRect(x: signs.x < 0 ? anchor.x - width : anchor.x,
                      y: signs.y < 0 ? anchor.y - height : anchor.y, width: width, height: height)
    }
}

/// Orthogonal transforms preserve pixel resolution and vectors; rotating never
/// allocates another full-size image or consumes a bitmap per undo step.
struct ImageEditGeometry {
    let crop: CGRect
    var turns = 0
    var mirrorX = false
    var mirrorY = false
    var size: CGSize { turns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width) }
    var transform: CGAffineTransform {
        var t: CGAffineTransform
        switch (turns % 4 + 4) % 4 {
        case 1: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: crop.maxY, ty: -crop.minX)
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: crop.maxX, ty: crop.maxY)
        case 3: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -crop.minY, ty: crop.maxX)
        default: t = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        }
        if mirrorX { t.a = -t.a; t.c = -t.c; t.tx = size.width - t.tx }
        if mirrorY { t.b = -t.b; t.d = -t.d; t.ty = size.height - t.ty }
        return t
    }
}

@MainActor
final class ImageEditDocument: ObservableObject {
    struct State {
        var crop: CGRect
        var annotations: [ImageAnnotation] = []
        var turns = 0
        var mirrorX = false
        var mirrorY = false
        var geometry: ImageEditGeometry { ImageEditGeometry(crop: crop, turns: turns, mirrorX: mirrorX, mirrorY: mirrorY) }
    }
    let sourceURL: URL
    let image: CGImage
    private let preview: NSImage
    @Published private(set) var state: State
    @Published var tool: ImageEditTool = .brush
    @Published var color = NSColor.systemRed
    @Published var width: CGFloat = 6
    @Published var eraserWidth: CGFloat = 32
    @Published var highlightWidth: CGFloat = 24
    @Published var mosaicSize: CGFloat = 16
    var toolSize: CGFloat {
        get {
            switch tool {
            case .eraser: return eraserWidth
            case .highlighter: return highlightWidth
            case .mosaic: return mosaicSize
            default: return width
            }
        }
        set {
            switch tool {
            case .eraser: eraserWidth = newValue
            case .highlighter: highlightWidth = newValue
            case .mosaic: mosaicSize = newValue
            default: width = newValue
            }
        }
    }
    var toolRange: ClosedRange<CGFloat> {
        switch tool {
        case .eraser, .highlighter: return 4...100
        case .mosaic: return 8...80
        default: return 2...24
        }
    }
    @Published var fontSize: CGFloat = 32
    @Published var text = ""
    @Published var cropSelection: CGRect?
    @Published private(set) var cropPreset: ImageCropPreset?
    var visibleCropSelection: CGRect? { cropSelection?.applying(state.geometry.transform) }
    func setVisibleCropSelection(_ rect: CGRect) {
        cropSelection = rect.applying(state.geometry.transform.inverted())
    }
    func cancelCrop() { cropSelection = nil; cropPreset = nil }
    @Published var message = ""
    @Published private(set) var undoStates: [State] = []
    private var redoStates: [State] = []
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var hasEdits: Bool {
        !state.annotations.isEmpty || state.crop != fullRect || state.turns != 0 || state.mirrorX || state.mirrorY
    }
    var displaySize: CGSize { state.geometry.size }
    var fullRect: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    init(url: URL, image: CGImage) {
        sourceURL = url
        self.image = image
        preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        state = State(crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let factor = max(1, CGFloat(image.width) / 1600)
        width = min(24, 6 * factor)
        fontSize = min(96, 32 * factor)
    }

    static func load(_ url: URL) throws -> ImageEditDocument {
        // NSImage decodes orientation metadata and handles the usual macOS image formats.
        guard let source = NSImage(contentsOf: url),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "Clipline.ImageEditor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: C("Could not read this image.", "无法读取这张图片。", "無法讀取這張圖片。")])
        }
        return ImageEditDocument(url: url, image: image)
    }

    private func commit(_ next: State) {
        undoStates.append(state)
        if undoStates.count > 40 { undoStates.removeFirst() }
        redoStates.removeAll()
        state = next
        cancelCrop()
        message = ""
    }
    func add(_ input: ImageAnnotation) {
        var annotation = input
        guard !annotation.points.isEmpty,
              annotation.tool != .text || !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if annotation.tool == .mosaic {
            guard let first = annotation.points.first, let last = annotation.points.last else { return }
            let rect = ImageAnnotation.rectangle(first, last).integral.intersection(state.crop)
            guard !rect.isNull, rect.width >= 2, rect.height >= 2,
                  let snapshot = try? renderedImage(oriented: false),
                  let region = snapshot.cropping(to: rect.offsetBy(dx: -state.crop.minX, dy: -state.crop.minY)),
                  let context = CGContext(data: nil, width: max(1, Int(ceil(rect.width / annotation.width))),
                                          height: max(1, Int(ceil(rect.height / annotation.width))), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(region, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            annotation.mosaicImage = context.makeImage()
            annotation.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
        }
        var next = state
        next.annotations.append(annotation)
        commit(next)
    }
    func applyCrop() {
        guard let selection = cropSelection else { return }
        let rect = selection.standardized.intersection(state.crop).integral.intersection(state.crop)
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return }
        var next = state
        next.crop = rect
        commit(next)
    }
    func selectCropPreset(_ preset: ImageCropPreset) {
        guard let rect = preset.frame(in: displaySize) else { return }
        tool = .crop
        cropPreset = preset
        setVisibleCropSelection(rect)
        message = ""
    }
    func rotate(clockwise: Bool) {
        var next = state
        // Mirroring changes the direction of a turn in source coordinates.
        let delta = (next.mirrorX != next.mirrorY ? -1 : 1) * (clockwise ? 1 : -1)
        next.turns = (next.turns + delta + 4) % 4
        commit(next)
    }
    func flip(horizontal: Bool) {
        var next = state
        if horizontal { next.mirrorX.toggle() } else { next.mirrorY.toggle() }
        commit(next)
    }
    func undo() {
        guard let previous = undoStates.last else { return }
        redoStates.append(state)
        undoStates.removeLast()
        state = previous
        cancelCrop()
        message = ""
    }
    func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(state)
        state = next
        cancelCrop()
        message = ""
    }
    func reset() {
        guard hasEdits else { cancelCrop(); return }
        commit(State(crop: fullRect))
    }

    /// Both canvas and export use exactly the same drawing code and top-left transform.
    func draw(pending: ImageAnnotation? = nil) {
        preview.draw(in: fullRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for annotation in state.annotations { draw(annotation) }
        if let pending { draw(pending) }
    }
    private func draw(_ annotation: ImageAnnotation) {
        guard annotation.tool == .eraser else { annotation.draw(); return }
        guard let context = NSGraphicsContext.current?.cgContext, let first = annotation.points.first else { return }
        context.saveGState()
        if annotation.points.count == 1 {
            context.addEllipse(in: CGRect(x: first.x - annotation.width / 2, y: first.y - annotation.width / 2,
                                          width: annotation.width, height: annotation.width))
        } else {
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            context.setLineWidth(annotation.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
        }
        context.clip()
        preview.draw(in: fullRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState()
    }
    func renderedImage(oriented: Bool = true) throws -> CGImage {
        let geometry = oriented ? state.geometry : ImageEditGeometry(crop: state.crop)
        let size = geometry.size
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "Clipline.ImageEditor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: C("Could not export this image.", "无法导出这张图片。", "無法匯出這張圖片。")])
        }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(geometry.transform)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
    func pngData() throws -> Data {
        let output = try renderedImage()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }
    func copy(to pasteboard: NSPasteboard = .general) throws {
        let data = try pngData()
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw CocoaError(.fileWriteUnknown) }
        message = C("Copied", "已复制", "已複製")
    }
    /// A derived system screenshot remains discoverable when the user's capture
    /// folder is Desktop, where the watcher intentionally excludes ordinary photos.
    func preserveCaptureTag(on destination: URL) {
        let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
        sourceURL.withUnsafeFileSystemRepresentation { source in
            guard let source else { return }
            let size = getxattr(source, attribute, nil, 0, 0, 0)
            guard size > 0, size <= 16384 else { return }
            var bytes = [UInt8](repeating: 0, count: size)
            let count = bytes.withUnsafeMutableBytes { getxattr(source, attribute, $0.baseAddress, size, 0, 0) }
            guard count == size else { return }
            destination.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = bytes.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            }
        }
    }
    /// Do not overwrite the screenshot or a prior edit. A no-overwrite write also
    /// handles another writer taking the chosen name between checking and saving.
    @discardableResult func saveCopy() throws -> URL {
        let data = try pngData()
        let stem = sourceURL.deletingPathExtension().lastPathComponent + "-edited"
        let directory = sourceURL.deletingLastPathComponent()
        for index in 1...10000 {
            let name = stem + (index == 1 ? "" : "-\(index)") + ".png"
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                preserveCaptureTag(on: destination)
                message = C("Saved a copy: ", "副本已保存：", "副本已儲存：") + name
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

/// A native canvas accepts the very first click even above another application's
/// full-screen window. SwiftUI controls never drive the image's pixel resolution.
@MainActor
final class ImageEditCanvas: NSView {
    var document: ImageEditDocument { didSet {
        if lastTool != document.tool { cancelGesture(); lastTool = document.tool }
        needsDisplay = true
    } }
    private var pending: ImageAnnotation?
    private var start: CGPoint?
    private enum CropAction { case create, move(CGRect), resize(CGRect, ImageCropHandle) }
    private var cropAction: CropAction?
    private var cropStart: CGPoint?
    private var lastTool: ImageEditTool = .brush
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(document: ImageEditDocument) {
        self.document = document
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var imageFrame: CGRect {
        let size = document.displaySize
        let available = bounds.insetBy(dx: 22, dy: 22)
        let scale = max(0.001, min(available.width / size.width, available.height / size.height))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
    private var scale: CGFloat { imageFrame.width / document.displaySize.width }
    func imagePoint(_ point: CGPoint, clamped: Bool) -> CGPoint? {
        let rect = imageFrame
        guard clamped || rect.contains(point) else { return nil }
        let visible = CGPoint(x: min(rect.width, max(0, point.x - rect.minX)) / scale,
                              y: min(rect.height, max(0, point.y - rect.minY)) / scale)
        return visible.applying(document.state.geometry.transform.inverted())
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        let rect = imageFrame
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        transform.concat()
        let geometry = document.state.geometry.transform
        let orientation = NSAffineTransform()
        orientation.transformStruct = NSAffineTransformStruct(m11: geometry.a, m12: geometry.b, m21: geometry.c,
                                                              m22: geometry.d, tX: geometry.tx, tY: geometry.ty)
        orientation.concat()
        document.draw(pending: pending)
        NSGraphicsContext.restoreGraphicsState()
        if let selection = document.cropSelection {
            let oriented = selection.applying(document.state.geometry.transform)
            let selected = CGRect(x: rect.minX + oriented.minX * scale, y: rect.minY + oriented.minY * scale,
                                  width: oriented.width * scale, height: oriented.height * scale)
            let shade = NSBezierPath(rect: rect)
            shade.appendRect(selected)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            shade.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selected)
            border.lineWidth = 1.5
            border.stroke()
            let grid = NSBezierPath()
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                grid.move(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.minY))
                grid.line(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.maxY))
                grid.move(to: CGPoint(x: selected.minX, y: selected.minY + selected.height * fraction))
                grid.line(to: CGPoint(x: selected.maxX, y: selected.minY + selected.height * fraction))
            }
            NSColor.white.withAlphaComponent(0.35).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()
            if document.cropPreset?.isFixedSize != true {
                NSColor.white.setFill()
                for handle in ImageCropHandle.allCases {
                    let point = handle.point(in: selected)
                    CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8).fill()
                }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        if document.tool == .crop {
            guard imageFrame.insetBy(dx: -10, dy: -10).contains(local),
                  let source = imagePoint(local, clamped: true) else { return }
            let point = source.applying(document.state.geometry.transform)
            cropStart = point
            if let rect = document.visibleCropSelection {
                if document.cropPreset?.isFixedSize != true,
                   let handle = ImageCropHandle.allCases.min(by: {
                       let a = $0.point(in: rect), b = $1.point(in: rect)
                       return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
                   }), hypot(handle.point(in: rect).x - point.x, handle.point(in: rect).y - point.y) <= 9 / scale {
                    cropAction = .resize(rect, handle)
                } else if rect.contains(point) { cropAction = .move(rect) }
                else if document.cropPreset?.isFixedSize == true {
                    let moved = ImageCropFrame.moved(rect, by: CGPoint(x: point.x - rect.midX, y: point.y - rect.midY), in: document.displaySize)
                    document.setVisibleCropSelection(moved)
                    cropAction = .move(moved)
                } else { cropAction = .create; document.setVisibleCropSelection(CGRect(origin: point, size: .zero)) }
            } else { cropAction = .create; document.setVisibleCropSelection(CGRect(origin: point, size: .zero)) }
            needsDisplay = true
            return
        }
        guard let point = imagePoint(local, clamped: false) else { return }
        start = point
        if document.tool == .text {
            document.add(ImageAnnotation(tool: .text, points: [point], color: document.color,
                                         width: document.width, text: document.text, fontSize: document.fontSize))
            start = nil
        } else {
            pending = ImageAnnotation(tool: document.tool, points: [point], color: document.color, width: document.toolSize)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamped: true) else { return }
        if document.tool == .crop, let cropAction, let cropStart {
            let visible = point.applying(document.state.geometry.transform)
            let delta = CGPoint(x: visible.x - cropStart.x, y: visible.y - cropStart.y)
            let rect: CGRect
            switch cropAction {
            case .create:
                rect = ImageCropFrame.created(from: cropStart, to: visible, in: document.displaySize, ratio: document.cropPreset?.aspectRatio)
            case let .move(initial):
                rect = ImageCropFrame.moved(initial, by: delta, in: document.displaySize)
            case let .resize(initial, handle):
                rect = ImageCropFrame.resized(initial, handle: handle, by: delta, in: document.displaySize, ratio: document.cropPreset?.aspectRatio)
            }
            document.setVisibleCropSelection(rect)
            needsDisplay = true
            return
        }
        guard let start else { return }
        if [.brush, .highlighter, .eraser].contains(pending?.tool ?? .crop) {
            if let last = pending?.points.last, hypot(last.x - point.x, last.y - point.y) >= 0.5 / scale {
                pending?.points.append(point)
            }
        } else { pending?.points = [start, point] }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if start != nil || cropStart != nil { mouseDragged(with: event) }
        if let pending { document.add(pending) }
        self.pending = nil
        start = nil
        cropAction = nil; cropStart = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelGesture(); document.cancelCrop() }
        else if event.keyCode == 36 && document.tool == .crop { document.applyCrop() }
        else { super.keyDown(with: event) }
    }
    override func resetCursorRects() {
        guard document.tool == .crop else { return }
        addCursorRect(imageFrame, cursor: .crosshair)
        if let selection = document.visibleCropSelection {
            let rect = CGRect(x: imageFrame.minX + selection.minX * scale, y: imageFrame.minY + selection.minY * scale,
                              width: selection.width * scale, height: selection.height * scale)
            addCursorRect(rect.insetBy(dx: 9, dy: 9), cursor: .openHand)
            if document.cropPreset?.isFixedSize != true {
                for handle in ImageCropHandle.allCases {
                    let point = handle.point(in: rect)
                    addCursorRect(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18), cursor: .crosshair)
                }
            }
        }
    }
    func cancelGesture() { pending = nil; start = nil; cropAction = nil; cropStart = nil; needsDisplay = true }
}

private struct ImageCanvasView: NSViewRepresentable {
    @ObservedObject var document: ImageEditDocument
    func makeNSView(context: Context) -> ImageEditCanvas { ImageEditCanvas(document: document) }
    func updateNSView(_ view: ImageEditCanvas, context: Context) {
        if view.document.tool != document.tool { view.cancelGesture() }
        view.document = document
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

private final class ImageEditorHostingView: NSHostingView<ImageEditorView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ImageEditorView: View {
    @ObservedObject var document: ImageEditDocument
    let copy: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(ImageEditTool.allCases) { tool in
                            Button {
                                document.cancelCrop()
                                document.tool = tool
                                if tool == .highlighter { document.color = .systemYellow }
                                if tool == .cover { document.color = .black }
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: tool.symbol).font(.system(size: 14))
                                    Text(tool.title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                                }.frame(minWidth: 28)
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .background(document.tool == tool ? Color.accentColor.opacity(0.16) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).help(tool.title)
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: 44)
                Spacer(minLength: 2)
                Button(action: document.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.canUndo).help(C("Undo", "撤销", "復原"))
                Button(action: document.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.canRedo).help(C("Redo", "重做", "重做"))
                Button(C("Reset", "重置", "重設"), action: document.reset).disabled(!document.hasEdits)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 8) {
                if document.tool != .crop {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Button { document.color = color } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 17, height: 17)
                            .overlay(Circle().stroke(document.color == color ? Color.accentColor : .gray.opacity(0.4), lineWidth: document.color == color ? 3 : 1))
                    }.buttonStyle(.plain).accessibilityLabel(color.accessibilityName)
                }
                }
                if document.tool == .text {
                    TextField(C("Enter text, then click the image", "输入文字后，点击图片放置", "輸入文字後，點選圖片放置"), text: $document.text)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    Text("\(Int(document.fontSize))").monospacedDigit().frame(width: 24)
                    Slider(value: $document.fontSize, in: 12...120).frame(width: 80)
                        .accessibilityLabel(C("Text size", "字号", "字級"))
                } else if document.tool == .crop {
                    Text(document.cropPreset?.isFixedSize == true
                         ? C("Drag the frame to choose the area", "拖动裁切框选择保留区域", "拖曳裁切框選取保留區域")
                         : C("Move the frame; drag corners to resize", "拖动裁切框，拖动四角调整大小", "拖曳裁切框，拖曳四角調整大小"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(C("Drag to select an area", "拖动选择裁切区域", "拖曳選取裁切區域"))
                    Spacer(minLength: 2)
                    Menu(document.cropPreset?.title ?? C("Quick crop", "常用裁切", "常用裁切")) {
                        Button(C("Free crop", "自由裁切", "自由裁切"), action: document.cancelCrop)
                        Section(C("Aspect ratio", "常用比例", "常用比例")) {
                            ForEach(Array(ImageCropPreset.ratios.enumerated()), id: \.offset) { _, preset in
                                Button(preset.title) { document.selectCropPreset(preset) }
                            }
                        }
                        Section(C("Pixel size", "固定尺寸", "固定尺寸")) {
                            ForEach(Array(ImageCropPreset.sizes.enumerated()), id: \.offset) { _, preset in
                                Button(preset.title) { document.selectCropPreset(preset) }
                                    .disabled(preset.frame(in: document.displaySize) == nil)
                            }
                        }
                    }.fixedSize()
                    Button(C("Cancel crop", "取消裁切", "取消裁切"), action: document.cancelCrop)
                        .disabled(document.cropSelection == nil)
                    Button(C("Apply crop", "应用裁切", "套用裁切"), action: document.applyCrop)
                        .disabled((document.cropSelection?.width ?? 0) < 2 || (document.cropSelection?.height ?? 0) < 2)
                } else {
                    Text(document.tool == .mosaic ? C("Block size", "颗粒大小", "顆粒大小") : C("Width", "粗细", "粗細")).font(.caption)
                    Slider(value: Binding(get: { document.toolSize }, set: { document.toolSize = $0 }), in: document.toolRange).frame(width: 90)
                    Text("\(Int(document.toolSize))").font(.caption).monospacedDigit().frame(width: 18)
                    Spacer(minLength: 2)
                }
            }.frame(height: 26).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ImageCanvasView(document: document).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(document.displaySize.width)) × \(Int(document.displaySize.height)) px").font(.caption).monospacedDigit()
                    Text(document.message.isEmpty ? C("Save creates a PNG copy and keeps the original.", "保存为 PNG 副本，保留原图。", "儲存為 PNG 副本，保留原圖。") : document.message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(document.message)
                }
                Spacer(minLength: 0)
                Button(C("Copy", "复制", "複製"), action: copy)
                Menu {
                    Button(C("Rotate clockwise", "顺时针旋转", "順時針旋轉")) { document.rotate(clockwise: true) }
                    Button(C("Rotate counterclockwise", "逆时针旋转", "逆時針旋轉")) { document.rotate(clockwise: false) }
                    Button(C("Flip horizontally", "水平翻转", "水平翻轉")) { document.flip(horizontal: true) }
                    Button(C("Flip vertically", "垂直翻转", "垂直翻轉")) { document.flip(horizontal: false) }
                    Divider()
                    Button(C("Save as…", "另存为…", "另存新檔…"), action: saveAs)
                } label: {
                    Image(systemName: "ellipsis")
                }.menuStyle(.borderlessButton).fixedSize()
                Button(C("Save", "保存", "儲存"), action: save).buttonStyle(.borderedProminent)
            }.padding(12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Titlebar and content have their final geometry before the first publication.
/// This panel takes keyboard focus without activating Clipline or switching Spaces.
final class ImageEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let editingText = firstResponder is NSTextView
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where !editingText: onCopy?(); return true
            case "s": onSave?(); return true
            case "z" where !editingText: event.modifierFlags.contains(.shift) ? onRedo?() : onUndo?(); return true
            case "w": performClose(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    init(frame: CGRect) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: min(600, frame.width), height: min(400, frame.height))
        setFrame(frame, display: false)
        animationBehavior = .none
    }
}

@MainActor
final class ImageEditorController: NSObject, NSWindowDelegate {
    private(set) var panel: ImageEditorPanel?
    private(set) var document: ImageEditDocument?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onSaved: ((URL) -> Void)?

    func open(_ url: URL, on screen: NSScreen?) {
        do {
            let document = try ImageEditDocument.load(url)
            let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let next = makePanel(document: document, visible: visible)
            panel?.close()
            self.document = document
            panel = next
            next.delegate = self
            onVisibilityChanged?(true)
            // No NSApp.activate and no NSWorkspace image launch: stay in the current Space.
            next.orderFrontRegardless()
            next.makeKey()
        } catch { showError(error) }
    }
    /// Also used by offscreen verification; never publishes a window by itself.
    func makePanel(document: ImageEditDocument, visible: CGRect) -> ImageEditorPanel {
        let panel = ImageEditorPanel(frame: EditorWindowLayout.frame(in: visible))
        panel.title = C("Edit image", "编辑图片", "編輯圖片") + " — " + document.sourceURL.lastPathComponent
        panel.onCopy = { [weak self] in self?.copy() }
        panel.onSave = { [weak self] in self?.save() }
        panel.onUndo = { [weak document] in document?.undo() }
        panel.onRedo = { [weak document] in document?.redo() }
        let content = ImageEditorHostingView(rootView: ImageEditorView(document: document, copy: { [weak self] in self?.copy() },
                                                            save: { [weak self] in self?.save() },
                                                            saveAs: { [weak self] in self?.saveAs() }))
        content.sizingOptions = []
        panel.contentView = content
        panel.setFrame(EditorWindowLayout.frame(in: visible), display: false)
        content.layoutSubtreeIfNeeded()
        return panel
    }
    private func copy() {
        guard let document else { return }
        do { try document.copy() } catch { showError(error) }
    }
    private func save() {
        guard let document else { return }
        do {
            let saved = try document.saveCopy()
            onSaved?(saved)
        } catch { showError(error) }
    }
    private func saveAs() {
        guard let panel, let document else { return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = document.sourceURL.deletingPathExtension().lastPathComponent + "-edited.png"
        picker.directoryURL = document.sourceURL.deletingLastPathComponent()
        picker.beginSheetModal(for: panel) { [weak self, weak document] response in
            guard response == .OK, let self, let document, let destination = picker.url else { return }
            do {
                // Explicit Save As may replace a file only after the system's replacement confirmation.
                guard destination.standardizedFileURL.resolvingSymlinksInPath() != document.sourceURL.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw NSError(domain: "Clipline.ImageEditor", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: C("Choose a different filename to keep the original.", "请选择其他文件名，保留原图。", "請選擇其他檔名，保留原圖。")])
                }
                try document.pngData().write(to: destination, options: .atomic)
                document.preserveCaptureTag(on: destination)
                document.message = C("Saved a copy: ", "副本已保存：", "副本已儲存：") + destination.lastPathComponent
                self.onSaved?(destination)
            } catch { self.showError(error) }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = C("Image editor", "图片编辑器", "圖片編輯器")
        alert.informativeText = error.localizedDescription
        if let panel { alert.beginSheetModal(for: panel) }
        else { NSSound.beep(); log.error("Image editor: \(error.localizedDescription, privacy: .public)") }
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel = nil
        document = nil
        onVisibilityChanged?(false)
    }
    func stop() { panel?.close() }
}
