import AppKit
import SwiftUI
import Vision

/// Uses invented images, a private pasteboard and offscreen panels only.
@main
struct EditorWindowChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipline-editor-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("原图 #1.png")
        var pixels = [UInt8](repeating: 255, count: 80 * 60 * 4)
        for y in 0..<60 {
            for x in 0..<80 {
                let offset = (y * 80 + x) * 4
                if y < 10 { pixels[offset] = 0; pixels[offset + 1] = 0 }
                if y >= 50 { pixels[offset] = 0; pixels[offset + 2] = 0 }
            }
        }
        for channel in 0..<4 { pixels[(30 * 80 + 79) * 4 + channel] = 0 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let fixtureImage = CGImage(width: 80, height: 60, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 80 * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bitmap = NSBitmapImageRep(cgImage: fixtureImage)
        let original = bitmap.representation(using: .png, properties: [:])!
        try original.write(to: url)
        let doc = try ImageEditDocument.load(url)
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
            NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }
        func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
            let p = pixel(image, x, y)
            return p.redComponent > 0.8 && p.greenComponent < 0.2 && p.blueComponent < 0.2
        }
        let unchanged = try doc.renderedImage()
        check(unchanged.width == 80 && unchanged.height == 60, "exports original pixel dimensions")
        check(pixel(unchanged, 10, 3).blueComponent > 0.9 && pixel(unchanged, 10, 55).greenComponent > 0.9,
              "top and bottom of the original are not flipped")
        check(pixel(unchanged, 79, 30).alphaComponent < 0.01, "PNG alpha is retained")
        check(!doc.hasEdits && !doc.canUndo && !doc.canRedo, "new document is clean")
        doc.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 10, y: 20), CGPoint(x: 65, y: 20)], color: .red, width: 4))
        check(isRed(try doc.renderedImage(), 35, 20), "brush lands at the correct image pixel")
        check(!isRed(try doc.renderedImage(), 35, 40), "brush is not mirrored vertically")
        doc.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 15, y: 35)], color: .red, width: 5))
        check(isRed(try doc.renderedImage(), 15, 35), "a click paints a visible dot")
        doc.add(ImageAnnotation(tool: .arrow, points: [CGPoint(x: 30, y: 40), CGPoint(x: 65, y: 40)], color: .red, width: 2))
        let arrow = try doc.renderedImage()
        check(isRed(arrow, 45, 40) && isRed(arrow, 56, 35), "arrow shaft and arrowhead are rendered")
        doc.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 60, y: 45), CGPoint(x: 40, y: 28)], color: .red, width: 2))
        let framed = try doc.renderedImage()
        check(isRed(framed, 40, 32) && !isRed(framed, 50, 32), "reverse-drag frame has an empty interior")
        let annotations = doc.state.annotations.count
        doc.add(ImageAnnotation(tool: .text, points: [CGPoint(x: 1, y: 1)], color: .black, width: 2, text: "  \n ", fontSize: 14))
        check(doc.state.annotations.count == annotations, "empty text does not create an undo step")
        doc.add(ImageAnnotation(tool: .text, points: [CGPoint(x: 3, y: 25)], color: .black, width: 2, text: "Test", fontSize: 14))
        let withText = try doc.renderedImage()
        let darkPixels = (25..<42).flatMap { y in (3..<30).map { x in pixel(withText, x, y).redComponent < 0.3 } }.filter { $0 }.count
        check(darkPixels > 20, "text is rendered in the expected top-left text bounds")
        doc.undo()
        check(doc.state.annotations.count == annotations && doc.canRedo, "undo removes the entire text operation")
        doc.redo()
        check(doc.state.annotations.count == annotations + 1 && !doc.canRedo, "redo restores text")
        doc.cropSelection = CGRect(x: 20, y: 12, width: 40, height: 30)
        doc.applyCrop()
        let cropped = try doc.renderedImage()
        check(cropped.width == 40 && cropped.height == 30, "crop uses original pixels, not display points")
        check(isRed(cropped, 15, 8), "annotations retain alignment after cropping")
        doc.cropSelection = CGRect(x: 25, y: 17, width: 20, height: 20)
        doc.applyCrop()
        check(doc.state.crop == CGRect(x: 25, y: 17, width: 20, height: 20), "second crop uses the original image coordinate system")
        doc.undo()
        check(doc.state.crop == CGRect(x: 20, y: 12, width: 40, height: 30), "undo restores the previous crop and annotations")
        doc.cropSelection = CGRect(x: -100, y: -100, width: 5, height: 5)
        doc.applyCrop()
        check(doc.state.crop.width == 40, "out-of-image crop is ignored")
        doc.cropSelection = CGRect(x: 10, y: 10, width: 60, height: 50)
        doc.applyCrop()
        check(doc.state.crop == CGRect(x: 20, y: 12, width: 40, height: 30), "crop cannot expand or leave the current crop")
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        try doc.copy(to: pb)
        let copied = NSBitmapImageRep(data: pb.data(forType: .png)!)!
        check(copied.pixelsWide == 40 && copied.pixelsHigh == 30 && !pb.types!.contains(.fileURL), "copy contains edited image pixels rather than an original file URL")
        let tag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let tagResult = url.withUnsafeFileSystemRepresentation { path in
            tag.withUnsafeBytes { setxattr(path!, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, tag.count, 0, 0) }
        }
        check(tagResult == 0, "fixture carries a system screenshot tag")
        let first = try doc.saveCopy()
        let second = try doc.saveCopy()
        let copiedTagSize = first.withUnsafeFileSystemRepresentation {
            getxattr($0!, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0)
        }
        check(copiedTagSize == tag.count, "saved system screenshot stays discoverable in Desktop capture history")
        check(first != second && first.lastPathComponent.hasSuffix("-edited.png") && second.lastPathComponent.hasSuffix("-edited-2.png"), "repeated saves never overwrite another edit")
        check(try Data(contentsOf: url) == original, "saving and copying preserve the original bytes")
        check(NSBitmapImageRep(data: try Data(contentsOf: first))!.pixelsWide == 40, "saved PNG contains the cropped edit")
        doc.reset()
        check(!doc.hasEdits && doc.state.crop == doc.fullRect && doc.state.annotations.isEmpty, "reset restores original pixels")
        doc.undo()
        check(doc.hasEdits && doc.state.crop.width == 40, "reset itself can be undone")
        doc.undo()
        doc.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 1, y: 20)], color: .black, width: 2))
        check(!doc.canRedo, "new edits discard the old redo branch")
        for index in 0..<50 { doc.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: index % 80, y: 20)], color: .black, width: 2)) }
        check(doc.undoStates.count == 40, "undo memory is bounded without per-stroke bitmap copies")
        let missing = ImageEditDocument(url: root.appendingPathComponent("missing/fail.png"), image: bitmap.cgImage!)
        do { _ = try missing.saveCopy(); fatalError("FAIL: nonexistent destination reported success") } catch { checks += 1 }
        do { _ = try ImageEditDocument.load(root.appendingPathComponent("missing.png")); fatalError("FAIL: missing image loaded") } catch { checks += 1 }

        let erase = try ImageEditDocument.load(url)
        erase.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 10, y: 20), CGPoint(x: 65, y: 20)], color: .red, width: 6))
        erase.add(ImageAnnotation(tool: .eraser, points: [CGPoint(x: 35, y: 15), CGPoint(x: 35, y: 25)], color: .black, width: 10))
        let erased = try erase.renderedImage()
        let restored = pixel(erased, 35, 20)
        check(restored.redComponent > 0.9 && restored.greenComponent > 0.9 && restored.blueComponent > 0.9,
              "eraser restores original pixels within the stroke")
        check(isRed(erased, 20, 20), "eraser retains nearby un-erased annotation")
        erase.undo()
        check(isRed(try erase.renderedImage(), 35, 20), "eraser can be undone")
        erase.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 79, y: 30)], color: .red, width: 6))
        erase.add(ImageAnnotation(tool: .eraser, points: [CGPoint(x: 79, y: 30)], color: .black, width: 6))
        check(pixel(try erase.renderedImage(), 79, 30).alphaComponent < 0.01, "eraser restores original transparency instead of painting white")
        let highlight = try ImageEditDocument.load(url)
        highlight.add(ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 10, y: 20), CGPoint(x: 65, y: 20)], color: .yellow, width: 12))
        let highlighted = pixel(try highlight.renderedImage(), 35, 20)
        check(highlighted.redComponent > 0.9 && highlighted.greenComponent > 0.9 && highlighted.blueComponent > 0.4,
              "highlighter is translucent")
        highlight.add(ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 35, y: 40)], color: .yellow, width: 12))
        check(pixel(try highlight.renderedImage(), 35, 40).blueComponent > 0.4, "a highlighter dot is also translucent")

        var checker = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 {
            let offset = (y * 64 + x) * 4
            let shade: UInt8 = (x + y) % 2 == 0 ? 0 : 255
            for channel in 0..<3 { checker[offset + channel] = shade }
        } }
        let checkerImage = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: CGDataProvider(data: Data(checker) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let mosaic = ImageEditDocument(url: url, image: checkerImage)
        mosaic.add(ImageAnnotation(tool: .mosaic, points: [CGPoint(x: 16, y: 16), CGPoint(x: 48, y: 48)], color: .black, width: 16))
        check(mosaic.state.annotations.last!.mosaicImage!.width == 2, "mosaic stores a coarse bitmap rather than the sensitive full-resolution patch")
        let blocked = try mosaic.renderedImage()
        let blockA = pixel(blocked, 20, 20), blockB = pixel(blocked, 21, 20)
        check(abs(blockA.redComponent - blockB.redComponent) < 0.01, "mosaic replaces high-frequency detail with flat blocks")
        check(abs(pixel(blocked, 2, 2).redComponent - pixel(blocked, 3, 2).redComponent) > 0.8, "mosaic preserves pixels outside its selection")
        mosaic.undo()
        let unblocked = try mosaic.renderedImage()
        check(abs(pixel(unblocked, 20, 20).redComponent - pixel(unblocked, 21, 20).redComponent) > 0.8, "mosaic can be undone without damaging the source")
        let redact = try ImageEditDocument.load(url)
        redact.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 10, y: 20), CGPoint(x: 65, y: 20)], color: .red, width: 5))
        redact.add(ImageAnnotation(tool: .mosaic, points: [CGPoint(x: 0, y: 12), CGPoint(x: 80, y: 45)], color: .black, width: 16))
        check(redact.state.annotations.last!.mosaicImage != nil, "mosaic also flattens earlier annotations into the masked patch")
        redact.add(ImageAnnotation(tool: .eraser, points: [CGPoint(x: 35, y: 20)], color: .black, width: 12))
        check(pixel(try redact.renderedImage(), 35, 20).greenComponent > 0.9, "eraser can restore original pixels through a mosaic patch")

        let asymmetricMosaic = try ImageEditDocument.load(url)
        asymmetricMosaic.add(ImageAnnotation(tool: .mosaic, points: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 10)], color: .black, width: 16))
        let mosaicTop = try asymmetricMosaic.renderedImage()
        check(pixel(mosaicTop, 30, 4).blueComponent > 0.9 && pixel(mosaicTop, 30, 55).greenComponent > 0.9,
              "mosaic samples the selected top region rather than a mirrored source region")
        asymmetricMosaic.rotate(clockwise: true)
        check(pixel(try asymmetricMosaic.renderedImage(), 55, 30).blueComponent > 0.9,
              "mosaic follows the same orientation as the original and other annotations")
        let shapes = try ImageEditDocument.load(url)
        shapes.add(ImageAnnotation(tool: .ellipse, points: [CGPoint(x: 10, y: 15), CGPoint(x: 50, y: 45)], color: .red, width: 4))
        let ellipse = try shapes.renderedImage()
        check(isRed(ellipse, 30, 15) && !isRed(ellipse, 30, 30), "ellipse renders a closed empty outline")
        shapes.add(ImageAnnotation(tool: .cover, points: [CGPoint(x: 15, y: 20), CGPoint(x: 45, y: 40)], color: .black, width: 4))
        let covered = pixel(try shapes.renderedImage(), 30, 30)
        check(covered.redComponent < 0.01 && covered.alphaComponent > 0.99, "solid cover fully replaces sensitive pixels")
        shapes.undo()
        check(pixel(try shapes.renderedImage(), 30, 30).redComponent > 0.9, "cover is undoable")
        let orientation = try ImageEditDocument.load(url)
        orientation.rotate(clockwise: true)
        let turned = try orientation.renderedImage()
        check(turned.width == 60 && turned.height == 80, "quarter turn swaps output pixel dimensions")
        check(pixel(turned, 55, 10).blueComponent > 0.9 && pixel(turned, 5, 10).greenComponent > 0.9, "clockwise turn maps top to right and bottom to left")
        orientation.flip(horizontal: true)
        let flipped = try orientation.renderedImage()
        check(pixel(flipped, 5, 10).blueComponent > 0.9 && pixel(flipped, 55, 10).greenComponent > 0.9, "horizontal flip operates in the displayed orientation")
        orientation.undo()
        check(orientation.state.turns == 1 && !orientation.state.mirrorX, "flip and rotation share normal undo history")
        let beforePreset = orientation.state.crop
        let beforePresetUndo = orientation.undoStates.count
        orientation.selectCropPreset(.ratio(16, 9))
        check(orientation.state.crop == beforePreset && orientation.undoStates.count == beforePresetUndo,
              "choosing a ratio only creates a crop frame without editing or adding undo history")
        check(try orientation.renderedImage().width == 60 && orientation.renderedImage().height == 80,
              "copy/export keeps the whole rotated image until crop is explicitly applied")
        orientation.cancelCrop()
        check(orientation.cropSelection == nil && orientation.cropPreset == nil && orientation.state.crop == beforePreset,
              "cancelling the preview leaves image pixels and committed edits intact")
        orientation.selectCropPreset(.ratio(16, 9))
        orientation.applyCrop()
        let presetRotated = try orientation.renderedImage()
        check(presetRotated.width == 60 && presetRotated.height == 33, "ratio crop operates on the rotated image's visible size")
        orientation.reset()
        check(!orientation.hasEdits && orientation.displaySize == CGSize(width: 80, height: 60), "reset restores crop, rotations, flips and annotations")
        orientation.selectCropPreset(.pixels(40, 30))
        orientation.applyCrop()
        check(orientation.state.crop == CGRect(x: 20, y: 15, width: 40, height: 30), "fixed pixel preset crops exactly and centers in the current image")
        orientation.undo()
        orientation.selectCropPreset(.pixels(1920, 1080))
        orientation.applyCrop()
        check(!orientation.hasEdits, "oversized pixel preset cannot upscale or destroy the image")
        orientation.selectCropPreset(.ratio(1, 1))
        orientation.applyCrop()
        check(orientation.state.crop == CGRect(x: 10, y: 0, width: 60, height: 60), "square preset takes the largest centered square")
        orientation.reset()
        orientation.flip(horizontal: false)
        check(pixel(try orientation.renderedImage(), 10, 3).greenComponent > 0.9, "vertical flip maps the bottom edge to the top")
        orientation.reset()
        for _ in 0..<4 { orientation.rotate(clockwise: true) }
        let restoredOrientation = try orientation.renderedImage()
        check(!orientation.hasEdits && pixel(restoredOrientation, 10, 3).blueComponent > 0.9, "four turns preserve original orientation without bitmap accumulation")
        for turn in 0..<4 { for flipX in [false, true] { for flipY in [false, true] {
            let geometry = ImageEditGeometry(crop: CGRect(x: 10, y: 7, width: 50, height: 30), turns: turn, mirrorX: flipX, mirrorY: flipY)
            let source = CGPoint(x: 23, y: 19)
            let roundtrip = source.applying(geometry.transform).applying(geometry.transform.inverted())
            check(hypot(roundtrip.x - source.x, roundtrip.y - source.y) < 0.001, "rotated/flipped canvas mapping roundtrips with cropped coordinates")
        } } }

        let controller = ImageEditorController()
        let visibleAreas = [CGRect(x: 0, y: 28, width: 1440, height: 850), CGRect(x: -1920, y: 70, width: 1920, height: 1000),
                            CGRect(x: 2000, y: -800, width: 1280, height: 750), CGRect(x: 0, y: 0, width: 640, height: 360)]
        for visible in visibleAreas {
            let expected = EditorWindowLayout.frame(in: visible)
            let panel = controller.makePanel(document: doc, visible: visible)
            check(panel.frame == expected && visible.contains(panel.frame), "complete final frame is set before showing, including small and secondary displays")
            check(abs(panel.frame.midX - visible.midX) <= 0.5 && abs(panel.frame.midY - visible.midY) <= 0.5, "panel starts centered")
            check(!panel.isVisible, "constructing and laying out the editor does not publish a huge intermediate window")
            check(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey && !panel.canBecomeMain,
                  "editor permits typing without activating the owner application")
            check(panel.collectionBehavior.contains(.fullScreenAuxiliary) && panel.collectionBehavior.contains(.canJoinAllSpaces) && !panel.hidesOnDeactivate,
                  "panel is configured to remain above a different application's full-screen Space")
            panel.close()
        }
        let canvas = ImageEditCanvas(document: doc)
        canvas.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
        let crop = doc.state.crop
        let point = canvas.imagePoint(CGPoint(x: canvas.imageFrame.midX, y: canvas.imageFrame.midY), clamped: false)!
        check(abs(point.x - crop.midX) < 0.01 && abs(point.y - crop.midY) < 0.01, "canvas maps scaled and cropped coordinates to original pixels")
        check(canvas.imagePoint(.zero, clamped: false) == nil, "outside image clicks are ignored")
        let clamped = canvas.imagePoint(.zero, clamped: true)!
        check(clamped == crop.origin, "outside drag clips to crop boundaries")
        orientation.reset()
        orientation.selectCropPreset(.pixels(40, 30))
        orientation.applyCrop()
        orientation.rotate(clockwise: true)
        orientation.flip(horizontal: true)
        let rotatedCanvas = ImageEditCanvas(document: orientation)
        rotatedCanvas.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
        let sourcePoint = CGPoint(x: 25, y: 25)
        let mapped = sourcePoint.applying(orientation.state.geometry.transform)
        let visiblePoint = CGPoint(x: rotatedCanvas.imageFrame.minX + mapped.x * rotatedCanvas.imageFrame.width / orientation.displaySize.width,
                                   y: rotatedCanvas.imageFrame.minY + mapped.y * rotatedCanvas.imageFrame.height / orientation.displaySize.height)
        let recovered = rotatedCanvas.imagePoint(visiblePoint, clamped: false)!
        check(hypot(recovered.x - sourcePoint.x, recovered.y - sourcePoint.y) < 0.001,
              "native canvas maps editing gestures through cropped, rotated and flipped display coordinates")
        let gestureDoc = try ImageEditDocument.load(url)
        let gestureCanvas = ImageEditCanvas(document: gestureDoc)
        let gesturePanel = ImageEditorPanel(frame: CGRect(x: -10000, y: -10000, width: 700, height: 420))
        gesturePanel.contentView = gestureCanvas
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            let visible = point.applying(gestureDoc.state.geometry.transform)
            let rect = gestureCanvas.imageFrame
            let local = CGPoint(x: rect.minX + visible.x * rect.width / gestureDoc.displaySize.width,
                                y: rect.minY + visible.y * rect.height / gestureDoc.displaySize.height)
            return NSEvent.mouseEvent(with: type, location: gestureCanvas.convert(local, to: nil), modifierFlags: [],
                                      timestamp: 1, windowNumber: gesturePanel.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        gestureDoc.color = .red
        gestureDoc.width = 4
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 20)))
        gestureCanvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: 20)))
        check(gestureDoc.state.annotations.isEmpty, "a native in-progress stroke does not create repeated undo operations")
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 60, y: 20)))
        let nativeStroke = try gestureDoc.renderedImage()
        check(gestureDoc.state.annotations.count == 1 && isRed(nativeStroke, 40, 20), "native mouse gesture commits a visible stroke on release")
        gestureDoc.tool = .crop
        gestureCanvas.document = gestureDoc
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 65, y: 45)))
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 15, y: 15)))
        check(abs(gestureDoc.cropSelection!.minX - 15) < 0.001 && abs(gestureDoc.cropSelection!.width - 50) < 0.001, "native reverse drag selects the intended crop")
        gestureDoc.applyCrop()
        check(try gestureDoc.renderedImage().width == 50, "applying native crop exports the selected image pixels")
        gestureDoc.tool = .text
        gestureDoc.text = "文字"
        gestureCanvas.document = gestureDoc
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 25)))
        check(gestureDoc.state.annotations.last?.text == "文字", "text tool places the entered text with the first click")
        gestureDoc.tool = .arrow
        gestureCanvas.document = gestureDoc
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 25)))
        gestureCanvas.cancelGesture()
        let beforeCancel = gestureDoc.state.annotations.count
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 35)))
        check(gestureDoc.state.annotations.count == beforeCancel, "cancelled gesture does not leave a stray annotation")
        // The actual native mouse path must support adjusting a preset, rather
        // than silently replacing or immediately applying it on mouse-up.
        gestureDoc.reset()
        gestureDoc.selectCropPreset(.pixels(40, 30))
        gestureCanvas.document = gestureDoc
        let historyBefore = gestureDoc.undoStates.count
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 40, y: 30)))
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 70, y: 50)))
        check(gestureDoc.visibleCropSelection == CGRect(x: 40, y: 30, width: 40, height: 30),
              "fixed-size frame moves with the pointer and stops at image bounds without resizing")
        check(!gestureDoc.hasEdits && gestureDoc.undoStates.count == historyBefore,
              "moving a crop frame never edits pixels or fills undo history")
        try gestureDoc.copy(to: pb)
        let uncroppedCopy = NSImage(data: pb.data(forType: .png)!)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        check(uncroppedCopy.width == 80 && uncroppedCopy.height == 60,
              "copy ignores an unconfirmed crop frame")
        gestureDoc.applyCrop()
        check(gestureDoc.displaySize == CGSize(width: 40, height: 30) && gestureDoc.cropSelection == nil && gestureDoc.cropPreset == nil,
              "explicit apply crops at the moved location and clears the selection constraint")
        gestureDoc.undo()
        check(!gestureDoc.hasEdits && gestureDoc.displaySize == CGSize(width: 80, height: 60),
              "one undo restores all pixels after an adjusted crop")
        gestureDoc.selectCropPreset(.ratio(1, 1))
        gestureCanvas.document = gestureDoc
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 70, y: 60)))
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 40)))
        let shrunk = gestureDoc.visibleCropSelection!
        check(abs(shrunk.minX - 10) < 0.001 && abs(shrunk.width - 40) < 0.001 && abs(shrunk.height - 40) < 0.001,
              "dragging a preset corner inward shrinks the frame while locking its aspect ratio")
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 30, y: 20)))
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 40)))
        check(gestureDoc.visibleCropSelection == CGRect(x: 30, y: 20, width: 40, height: 40),
              "dragging inside a resized ratio frame moves it without altering the selected size")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                     windowNumber: gesturePanel.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        gestureCanvas.keyDown(with: escape)
        check(gestureDoc.cropSelection == nil && gestureDoc.cropPreset == nil && !gestureDoc.hasEdits,
              "Escape cancels the adjusted frame without changing the original")
        gestureCanvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        gestureCanvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 30)))
        check(gestureDoc.visibleCropSelection == CGRect(x: 10, y: 10, width: 40, height: 20),
              "free crop is unlocked after cancelling a preset")
        gestureDoc.cancelCrop()
        gestureDoc.rotate(clockwise: true)
        gestureDoc.flip(horizontal: true)
        gestureDoc.selectCropPreset(.pixels(30, 20))
        gestureCanvas.document = gestureDoc
        func visibleMouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            mouse(type, at: point.applying(gestureDoc.state.geometry.transform.inverted()))
        }
        gestureCanvas.mouseDown(with: visibleMouse(.leftMouseDown, CGPoint(x: 30, y: 40)))
        gestureCanvas.mouseUp(with: visibleMouse(.leftMouseUp, CGPoint(x: 40, y: 65)))
        let movedRotated = gestureDoc.visibleCropSelection!
        check(movedRotated == CGRect(x: 25, y: 55, width: 30, height: 20),
              "frame movement uses visible coordinates after rotating and mirroring")
        let expectedSourceCrop = movedRotated.applying(gestureDoc.state.geometry.transform.inverted())
        gestureDoc.applyCrop()
        check(gestureDoc.state.crop == expectedSourceCrop && gestureDoc.displaySize == CGSize(width: 30, height: 20),
              "applying an adjusted rotated frame selects the intended original region")
        for handle in ImageCropHandle.allCases {
            for delta in [CGPoint(x: -12, y: -20), CGPoint(x: 15, y: 7), CGPoint(x: 10000, y: -10000)] {
                let rect = ImageCropFrame.resized(CGRect(x: 20, y: 20, width: 40, height: 30), handle: handle,
                                                 by: delta, in: CGSize(width: 100, height: 80), ratio: 4.0 / 3)
                check(rect.minX >= -0.001 && rect.minY >= -0.001 && rect.maxX <= 100.001 && rect.maxY <= 80.001
                      && abs(rect.width / rect.height - 4.0 / 3) < 0.001,
                      "every ratio corner remains proportional and in bounds even for extreme drags")
            }
        }
        for preset in ImageCropPreset.ratios {
            gestureDoc.reset()
            gestureDoc.selectCropPreset(preset)
            check(!gestureDoc.hasEdits && gestureDoc.displaySize == CGSize(width: 80, height: 60),
                  "every common ratio is a pending frame, never an immediate crop")
        }
        gesturePanel.close()
        var copies = 0, saves = 0, undos = 0, redos = 0
        let keys = ImageEditorPanel(frame: CGRect(x: -10000, y: -10000, width: 800, height: 600))
        keys.onCopy = { copies += 1 }; keys.onSave = { saves += 1 }; keys.onUndo = { undos += 1 }; keys.onRedo = { redos += 1 }
        for (key, shift) in [("c", false), ("s", false), ("z", false), ("z", true)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                                        timestamp: 1, windowNumber: keys.windowNumber, context: nil, characters: key,
                                        charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            check(keys.performKeyEquivalent(with: event), "local editor shortcut handles \(key)")
        }
        check(copies == 1 && saves == 1 && undos == 1 && redos == 1, "copy, save, undo and redo shortcuts route exactly once")
        keys.close()

        // Render only our invented editor far outside every user display.
        let suite = "local.clipline.editor-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguage(defaults: defaults, preferredLanguages: { ["zh-Hans"] }, appliesGlobally: true)
        language.selected = .zhHans
        let context = CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        let demo = ImageEditDocument(url: root.appendingPathComponent("示例图片.png"), image: context.makeImage()!)
        demo.add(ImageAnnotation(tool: .text, points: [CGPoint(x: 75, y: 60)], color: .black, width: 5, text: "Clipline 图片编辑", fontSize: 48))
        demo.add(ImageAnnotation(tool: .text, points: [CGPoint(x: 75, y: 145)], color: .darkGray, width: 5, text: "文字、画笔、箭头与框线", fontSize: 30))
        demo.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 70, y: 230), CGPoint(x: 490, y: 390)], color: .systemBlue, width: 7))
        demo.add(ImageAnnotation(tool: .arrow, points: [CGPoint(x: 740, y: 310), CGPoint(x: 520, y: 310)], color: .systemRed, width: 8))
        demo.add(ImageAnnotation(tool: .brush, points: [CGPoint(x: 80, y: 470), CGPoint(x: 180, y: 490), CGPoint(x: 280, y: 450), CGPoint(x: 390, y: 480)], color: .systemGreen, width: 9))
        let ownPanel = controller.makePanel(document: demo, visible: CGRect(x: -10000, y: -10000, width: 1440, height: 920))
        ownPanel.orderFrontRegardless()
        defer { ownPanel.orderOut(nil); ownPanel.close() }
        let host = ownPanel.contentView!
        let output = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for tool in [ImageEditTool.brush, .text, .mosaic, .eraser, .highlighter, .crop] {
            demo.tool = tool
            demo.text = "在图片上点击放置文字"
            if tool == .crop { demo.cropSelection = CGRect(x: 50, y: 40, width: 800, height: 500) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: snapshot)
            try snapshot.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("editor-preview-\(tool.rawValue).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: snapshot.cgImage!).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            check(labels.contains("复制") && labels.contains("保存") && labels.contains("裁切"), "\(tool) controls are rendered and readable: \(labels)")
            check(host.bounds.width <= 860 && host.bounds.height <= 640, "editor does not expand to the image's large original dimensions")
        }
        let line = Line(persistsScreenshots: false)
        let id = line.hang(url, quietly: true)!
        var opened: [URL] = []
        line.onRequestOpen = { opened.append($0) }
        line.open(id)
        check(opened == [url] && line.copiedID == nil && line.liveCount == 1, "long-press/menu routing passes the original and never copies or deletes it")
        var systemOpened: [URL] = []
        line.onRequestSystemOpen = { systemOpened.append($0) }
        let menuHost = NSHostingView(rootView: GrabArea(item: line.items.first(where: { $0.id == id })!, line: line))
        menuHost.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        menuHost.layoutSubtreeIfNeeded()
        func findGrab(_ view: NSView) -> GrabView? {
            if let grab = view as? GrabView { return grab }
            return view.subviews.compactMap { findGrab($0) }.first
        }
        let imageMenu = findGrab(menuHost)!.menuProvider()
        let editMenuItem = imageMenu.items.first(where: { $0.title == C("Edit image", "编辑图片", "編輯圖片") })!
        let systemMenuItem = imageMenu.items.first(where: { $0.title == L("Open", "Abrir") })!
        NSApp.sendAction(editMenuItem.action!, to: editMenuItem.target, from: editMenuItem)
        NSApp.sendAction(systemMenuItem.action!, to: systemMenuItem.target, from: systemMenuItem)
        check(opened == [url, url] && systemOpened == [url],
              "image menu independently offers the custom editor and explicit system Preview route")
        line.openInSystemEditor(UUID())
        check(systemOpened == [url] && line.liveCount == 1 && line.copiedID == nil,
              "system open preserves the screenshot, ignores stale cards and never touches the clipboard")
        check(try Data(contentsOf: url) == original, "all editor checks leave the source intact")
        print("PASS: \(checks) image editing, export, undo, native panel and offscreen layout checks")
    }
}
