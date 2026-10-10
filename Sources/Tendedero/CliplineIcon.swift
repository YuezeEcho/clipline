import AppKit

/// Draw the same clothesline motif as native vectors at application and menu sizes.
enum CliplineIcon {
    static func applicationImage(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = NSAffineTransform()
            scale.scale(by: size / 1024)
            scale.concat()
            let background = NSBezierPath(roundedRect: CGRect(x: 68, y: 68, width: 888, height: 888), xRadius: 200, yRadius: 200)
            NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.40, alpha: 1),
                       ending: NSColor(calibratedRed: 0.22, green: 0.61, blue: 0.62, alpha: 1))!.draw(in: background, angle: 75)
            let rope = NSBezierPath()
            rope.move(to: CGPoint(x: 112, y: 738))
            rope.curve(to: CGPoint(x: 912, y: 738), controlPoint1: CGPoint(x: 355, y: 650), controlPoint2: CGPoint(x: 669, y: 650))
            rope.lineWidth = 17
            rope.lineCapStyle = .round
            NSColor(calibratedRed: 0.99, green: 0.89, blue: 0.66, alpha: 1).setStroke()
            rope.stroke()
            // A second screenshot behind the main one makes this a clothesline,
            // rather than a single clipboard or document silhouette.
            card(frame: CGRect(x: 165, y: 320, width: 295, height: 305), angle: 9, pegHeight: 115, landscape: false)
            card(frame: CGRect(x: 380, y: 225, width: 425, height: 410), angle: -6, pegHeight: 120, landscape: true)
            return true
        }
    }

    private static func card(frame: CGRect, angle: CGFloat, pegHeight: CGFloat, landscape: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: frame.midX, yBy: frame.maxY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -frame.midX, yBy: -frame.maxY)
        transform.concat()
        let paper = NSBezierPath(roundedRect: frame, xRadius: 35, yRadius: 35)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        NSColor.white.setFill(); paper.fill()
        NSGraphicsContext.restoreGraphicsState()
        let content = frame.insetBy(dx: 24, dy: 24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: content, xRadius: 15, yRadius: 15).addClip()
        NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.96, alpha: 1).setFill(); content.fill()
        if landscape {
            NSColor(calibratedRed: 0.99, green: 0.73, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: content.maxX - 109, y: content.maxY - 116, width: 65, height: 65)).fill()
            mountain(in: content, peakX: 0.34, peakY: 0.69, color: NSColor(calibratedRed: 0.22, green: 0.54, blue: 0.60, alpha: 1))
            mountain(in: content, peakX: 0.78, peakY: 0.48, color: NSColor(calibratedRed: 0.32, green: 0.73, blue: 0.62, alpha: 1))
        } else {
            NSColor(calibratedRed: 0.60, green: 0.79, blue: 0.84, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: content.minX + 17, y: content.midY - 26, width: content.width - 34, height: content.height * 0.34), xRadius: 12, yRadius: 12).fill()
            NSColor(calibratedRed: 0.31, green: 0.55, blue: 0.62, alpha: 1).setStroke()
            for index in 0..<2 {
                let stroke = NSBezierPath(); stroke.lineWidth = 12; stroke.lineCapStyle = .round
                let y = content.minY + 32 + CGFloat(index) * 29
                stroke.move(to: CGPoint(x: content.minX + 23, y: y))
                stroke.line(to: CGPoint(x: content.maxX - 23 - CGFloat(index) * 45, y: y))
                stroke.stroke()
            }
        }
        // Screenshot framing corners remain visible at Dock/Finder icon sizes.
        NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.35, alpha: 0.9).setStroke()
        let corners = NSBezierPath(); corners.lineWidth = landscape ? 9 : 7; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
        let inset = content.insetBy(dx: 14, dy: 14)
        for x in [inset.minX, inset.maxX] {
            for y in [inset.minY, inset.maxY] {
                let dx: CGFloat = x == inset.minX ? 22 : -22
                let dy: CGFloat = y == inset.minY ? 22 : -22
                corners.move(to: CGPoint(x: x, y: y + dy)); corners.line(to: CGPoint(x: x, y: y)); corners.line(to: CGPoint(x: x + dx, y: y))
            }
        }
        corners.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let peg = CGRect(x: frame.midX - 20, y: frame.maxY - 40, width: 40, height: pegHeight)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: peg, xRadius: 16, yRadius: 16).fill()
        NSColor(calibratedWhite: 0.53, alpha: 1).setStroke()
        let notch = NSBezierPath(); notch.lineWidth = 5; notch.lineCapStyle = .round
        notch.move(to: CGPoint(x: peg.minX + 10, y: peg.midY)); notch.line(to: CGPoint(x: peg.maxX - 10, y: peg.midY)); notch.stroke()
    }

    private static func mountain(in rect: CGRect, peakX: CGFloat, peakY: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX - rect.width * 0.20, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX + rect.width * peakX, y: rect.minY + rect.height * peakY))
        path.line(to: CGPoint(x: rect.maxX + rect.width * 0.20, y: rect.minY))
        path.close(); color.setFill(); path.fill()
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let rope = NSBezierPath(); rope.lineWidth = 1.2; rope.lineCapStyle = .round
            rope.move(to: CGPoint(x: 1, y: 15))
            rope.curve(to: CGPoint(x: 17, y: 15), controlPoint1: CGPoint(x: 6, y: 12.5), controlPoint2: CGPoint(x: 12, y: 12.5))
            rope.stroke()
            for (x, y, width, height) in [(2.5, 4.5, 6.5, 7.0), (10.0, 2.5, 6.0, 9.0)] {
                let frame = CGRect(x: x, y: y, width: width, height: height)
                let card = NSBezierPath(roundedRect: frame, xRadius: 1, yRadius: 1); card.lineWidth = 1.1; card.stroke()
                NSBezierPath(roundedRect: CGRect(x: frame.midX - 0.8, y: frame.maxY - 0.6, width: 1.6, height: 3.8), xRadius: 0.5, yRadius: 0.5).fill()
                let photo = NSBezierPath(); photo.lineWidth = 0.85
                photo.move(to: CGPoint(x: frame.minX + 1.2, y: frame.minY + 1.8))
                photo.line(to: CGPoint(x: frame.midX, y: frame.minY + 3.7))
                photo.line(to: CGPoint(x: frame.maxX - 1.1, y: frame.minY + 1.8)); photo.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clipline"
        return image
    }
}
