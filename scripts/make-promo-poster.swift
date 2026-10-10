import AppKit
import CoreGraphics

@main
struct PromoPoster {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width: CGFloat = 960, height: CGFloat = 1520
        var media = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(output as CFURL, mediaBox: &media, [kCGPDFContextTitle as String: "Clipline 多彩宣传海报", kCGPDFContextAuthor as String: "Clipline"] as CFDictionary)!
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
        let ink = color(0x171A21), muted = color(0x606675)
        func box(_ rect: CGRect, _ fill: NSColor, radius: CGFloat = 20) {
            fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        @discardableResult func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat,
                                    _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                                    _ fill: NSColor? = nil, maxHeight: CGFloat = 1000) -> CGFloat {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size >= 60 ? 0 : 4
            let storage = NSTextStorage(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: fill ?? ink, .paragraphStyle: paragraph])
            let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: w, height: 10000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
            let range = manager.glyphRange(for: container), actual = ceil(manager.usedRect(for: container).maxY)
            precondition(actual <= maxHeight, "Text exceeds its allocated area: " + value)
            manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: x, y: y))
            return actual
        }
        func gradient(_ rect: CGRect, colors: [UInt32]) {
            context.saveGState(); context.clip(to: rect)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map { color($0).cgColor } as CFArray, locations: nil)!
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            context.restoreGState()
        }
        func symbol(_ name: String, x: CGFloat, y: CGFloat, size: CGFloat, tint: NSColor) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform(); transform.translateX(by: x, yBy: y); transform.scale(by: size / 24); transform.concat()
            tint.setStroke(); tint.setFill()
            func stroke(_ points: [CGPoint], close: Bool = false, fill: Bool = false) {
                let path = NSBezierPath(); path.lineWidth = 1.8; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }
                if close { path.close() }; if fill { path.fill() } else { path.stroke() }
            }
            func rect(_ frame: CGRect, radius: CGFloat = 2) {
                let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius); path.lineWidth = 1.8; path.stroke()
            }
            switch name {
            case "doc.on.clipboard":
                rect(CGRect(x: 5, y: 4, width: 14, height: 18))
                box(CGRect(x: 9, y: 2, width: 6, height: 4), tint, radius: 1.5)
                stroke([CGPoint(x: 9, y: 11), CGPoint(x: 15, y: 11)])
                stroke([CGPoint(x: 9, y: 16), CGPoint(x: 13, y: 16)])
            case "play.rectangle":
                rect(CGRect(x: 2, y: 5, width: 20, height: 14), radius: 3)
                stroke([CGPoint(x: 10, y: 9), CGPoint(x: 16, y: 12), CGPoint(x: 10, y: 15)], close: true, fill: true)
            case "pin.fill":
                stroke([CGPoint(x: 9, y: 3), CGPoint(x: 19, y: 7), CGPoint(x: 15, y: 10), CGPoint(x: 14, y: 16), CGPoint(x: 7, y: 13), CGPoint(x: 11, y: 9)], close: true, fill: true)
                stroke([CGPoint(x: 10, y: 14), CGPoint(x: 6, y: 22)])
            case "pencil.and.outline":
                stroke([CGPoint(x: 5, y: 18), CGPoint(x: 17, y: 5), CGPoint(x: 20, y: 8), CGPoint(x: 8, y: 21), CGPoint(x: 4, y: 22)], close: true)
                stroke([CGPoint(x: 15, y: 7), CGPoint(x: 18, y: 10)])
                stroke([CGPoint(x: 4, y: 12), CGPoint(x: 4, y: 4), CGPoint(x: 12, y: 4)])
            case "folder":
                stroke([CGPoint(x: 2, y: 20), CGPoint(x: 2, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 13, y: 8), CGPoint(x: 22, y: 8), CGPoint(x: 22, y: 20)], close: true)
            default:
                stroke([CGPoint(x: 5, y: 3), CGPoint(x: 5, y: 19), CGPoint(x: 10, y: 15), CGPoint(x: 14, y: 22), CGPoint(x: 17, y: 20), CGPoint(x: 13, y: 14), CGPoint(x: 20, y: 13)], close: true)
                stroke([CGPoint(x: 15, y: 3), CGPoint(x: 15, y: 1)])
                stroke([CGPoint(x: 19, y: 5), CGPoint(x: 21, y: 3)])
            }
        }
        color(0xFAFBFD).setFill(); media.fill()
        let logo = NSImage(contentsOfFile: "build/clipline-icon-preview.png")!
        logo.draw(in: CGRect(x: 57, y: 50, width: 65, height: 65), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        text("Clipline", 136, 58, 280, 29, .semibold)
        text("截图晾绳 · 全新功能集合", 138, 96, 400, 13, .medium, muted)
        box(CGRect(x: 740, y: 65, width: 154, height: 34), color(0xECE9FC), radius: 17)
        text("0.1.15  /  macOS", 758, 72, 130, 13, .medium, color(0x6950CC))

        text("让截图，", 60, 158, 830, 83, .semibold, ink, maxHeight: 110)
        text("变成一道风景。", 60, 257, 840, 83, .semibold, color(0x6656CE), maxHeight: 110)
        text("截图、录屏、复制过的文字。现在，都有了漂亮的去处。", 65, 373, 835, 20, .regular, muted, maxHeight: 45)

        // An illustrative product scene, made entirely from editable native vectors.
        let stage = CGRect(x: 48, y: 446, width: 864, height: 354)
        let stagePath = NSBezierPath(roundedRect: stage, xRadius: 38, yRadius: 38)
        NSGraphicsContext.saveGraphicsState()
        stagePath.addClip()
        gradient(stage, colors: [0xFADBD5, 0xE6DCF8, 0xD4ECF3, 0xFCEAB5])
        NSGraphicsContext.restoreGraphicsState()
        let rope = NSBezierPath(); rope.lineWidth = 2.5
        color(0xA69379).setStroke()
        rope.move(to: CGPoint(x: 65, y: 494))
        rope.curve(to: CGPoint(x: 895, y: 493), controlPoint1: CGPoint(x: 325, y: 529), controlPoint2: CGPoint(x: 635, y: 529))
        rope.stroke()
        func card(_ frame: CGRect, angle: CGFloat, fixed: Bool = false, draw: (CGRect) -> Void) {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: frame.midX, yBy: frame.minY); t.rotate(byDegrees: angle)
            t.translateX(by: -frame.midX, yBy: -frame.minY); t.concat()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = color(0x3F3560, 0.19)
            shadow.shadowBlurRadius = 17; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
            box(frame, .white, radius: 22)
            NSGraphicsContext.restoreGraphicsState()
            let inner = frame.insetBy(dx: 10, dy: 10)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: inner, xRadius: 15, yRadius: 15).addClip()
            draw(inner)
            NSGraphicsContext.restoreGraphicsState()
            let peg = CGRect(x: frame.midX - 6, y: frame.minY - 15, width: 12, height: 33)
            box(peg, fixed ? ink : color(0xF6F7FA), radius: 5)
            color(fixed ? 0x767983 : 0xC2C5CD).setStroke()
            let notch = NSBezierPath(); notch.lineWidth = 1.5
            notch.move(to: CGPoint(x: peg.minX + 3, y: peg.midY)); notch.line(to: CGPoint(x: peg.maxX - 3, y: peg.midY)); notch.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        card(CGRect(x: 104, y: 518, width: 246, height: 194), angle: -7) { rect in
            gradient(rect, colors: [0xFBECC8, 0xF7B6BC])
            color(0xFFB340).setFill(); NSBezierPath(ovalIn: CGRect(x: rect.maxX - 82, y: rect.minY + 24, width: 45, height: 45)).fill()
            let mountain = NSBezierPath(); mountain.move(to: CGPoint(x: rect.minX - 10, y: rect.maxY))
            mountain.line(to: CGPoint(x: rect.minX + 91, y: rect.minY + 82)); mountain.line(to: CGPoint(x: rect.maxX + 40, y: rect.maxY)); mountain.close()
            color(0x9C93DE).setFill(); mountain.fill()
            let foreground = NSBezierPath(); foreground.move(to: CGPoint(x: rect.minX - 20, y: rect.maxY))
            foreground.line(to: CGPoint(x: rect.maxX - 27, y: rect.minY + 114)); foreground.line(to: CGPoint(x: rect.maxX + 40, y: rect.maxY)); foreground.close()
            color(0x7064B0).setFill(); foreground.fill()
            color(0xFFFFFF, 0.85).setStroke()
            for (x, dx) in [(rect.minX + 10, CGFloat(16)), (rect.maxX - 10, CGFloat(-16))] {
                for (y, dy) in [(rect.minY + 10, CGFloat(16)), (rect.maxY - 10, CGFloat(-16))] {
                    let corner = NSBezierPath(); corner.lineWidth = 2.5
                    corner.move(to: CGPoint(x: x, y: y + dy)); corner.line(to: CGPoint(x: x, y: y)); corner.line(to: CGPoint(x: x + dx, y: y)); corner.stroke()
                }
            }
        }
        card(CGRect(x: 336, y: 527, width: 253, height: 159), angle: 5) { rect in
            box(rect, color(0xF9FCFF), radius: 14)
            text("复制过的好点子", rect.minX + 17, rect.minY + 24, rect.width - 34, 13, .medium, color(0x148C98))
            text("先留下灵感。\n再找回好点子。", rect.minX + 17, rect.minY + 58, rect.width - 34, 22, .medium, ink, maxHeight: 70)
        }
        card(CGRect(x: 620, y: 514, width: 226, height: 204), angle: -4) { rect in
            gradient(rect, colors: [0x7EB6D6, 0x6B68B2])
            color(0xC9E5EE, 0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX - 45, y: rect.minY + 15, width: 180, height: 180)).fill()
            box(CGRect(x: rect.midX - 27, y: rect.midY - 32, width: 54, height: 54), color(0xFFFFFF, 0.88), radius: 27)
            let play = NSBezierPath(); play.move(to: CGPoint(x: rect.midX - 6, y: rect.midY - 16))
            play.line(to: CGPoint(x: rect.midX + 11, y: rect.midY - 5)); play.line(to: CGPoint(x: rect.midX - 6, y: rect.midY + 6)); play.close()
            color(0x655A9B).setFill(); play.fill()
            text("悬停 · 静音预览", rect.minX + 59, rect.maxY - 36, rect.width - 76, 13, .medium, .white)
        }
        // The black peg visibly identifies a foreground pinned photo.
        card(CGRect(x: 550, y: 524, width: 126, height: 198), angle: 4, fixed: true) { rect in
            gradient(rect, colors: [0xFCECA4, 0xFFD5AC])
            let flowerCenter = CGPoint(x: rect.midX, y: rect.minY + 63)
            for i in 0..<8 {
                let theta = CGFloat(i) * .pi / 4
                let petal = CGRect(x: flowerCenter.x + cos(theta) * 24 - 14, y: flowerCenter.y + sin(theta) * 24 - 14, width: 28, height: 28)
                color(0xFFAF5C).setFill(); NSBezierPath(ovalIn: petal).fill()
            }
            color(0x8C6652).setFill(); NSBezierPath(ovalIn: CGRect(x: flowerCenter.x - 18, y: flowerCenter.y - 18, width: 36, height: 36)).fill()
            text("喜欢的照片", rect.minX + 13, rect.maxY - 43, rect.width - 26, 15, .medium, color(0x795646))
            text("一直在这里", rect.minX + 14, rect.maxY - 23, rect.width - 28, 10, .regular, color(0x9B7561))
        }
        text("截图轻轻落下，灵感随风轻晃。", 300, 773, 430, 13, .medium, color(0x6F6C87))

        text("好看之外，更好用。", 64, 845, 710, 32, .semibold)
        text("从截图晾绳出发，加入更多日常好用的新功能。", 66, 895, 815, 16, .regular, muted)
        struct Feature {
            let title: String, body: String, symbol: String, accent: UInt32, tint: UInt32, badge: String
        }
        let features: [Feature] = [
            .init(title: "剪贴板历史", body: "文字与图片，最近 100 条。\n去重、暂停，单击重新复制。", symbol: "doc.on.clipboard", accent: 0x13929A, tint: 0xE5F6F5, badge: "新增"),
            .init(title: "录屏悬停预览", body: "移上去，静音播放。\n移开，就停止。", symbol: "play.rectangle", accent: 0x7561C5, tint: 0xEEEAF9, badge: "新增"),
            .init(title: "固定喜欢的照片", body: "自由选位，黑夹子固定。\n重启后，依然在这里。", symbol: "pin.fill", accent: 0xC97B35, tint: 0xFFF1DE, badge: "新增"),
            .init(title: "更完整的图片编辑", body: "文字、箭头、马赛克、橡皮。\n裁切选框，确认后再应用。", symbol: "pencil.and.outline", accent: 0xC2638A, tint: 0xFAEAF1, badge: "升级"),
            .init(title: "保存目录跟随", body: "换个保存位置，晾绳跟着走。\n固定照片，不受影响。", symbol: "folder", accent: 0x4183BC, tint: 0xE8F2FC, badge: "新增"),
            .init(title: "更顺手的晾绳", body: "双击菜单栏空白处，展开收起。\n横向浏览，切换栏可隐藏。", symbol: "cursorarrow.click.2", accent: 0x4C956D, tint: 0xEBF6EF, badge: "升级")
        ]
        let tileW: CGFloat = 832 / 3 - 32 / 3
        for (i, feature) in features.enumerated() {
            let x: CGFloat = 64 + CGFloat(i % 3) * (tileW + 16)
            let y: CGFloat = 936 + CGFloat(i / 3) * 174
            box(CGRect(x: x, y: y, width: tileW, height: 158), .white, radius: 23)
            box(CGRect(x: x + 18, y: y + 18, width: 34, height: 34), color(feature.tint), radius: 10)
            symbol(feature.symbol, x: x + 25, y: y + 25, size: 20, tint: color(feature.accent))
            text(feature.badge, x + tileW - 48, y + 24, 36, 11, .medium, color(feature.accent))
            text(feature.title, x + 18, y + 63, tileW - 36, 20, .semibold, ink, maxHeight: 29)
            text(feature.body, x + 18, y + 97, tileW - 36, 13.5, .regular, muted, maxHeight: 51)
        }
        text("还有：即时截图 · 弹性下落与微风摇动 · 多语言 · 全新图标", 67, 1302, 830, 14, .medium, muted)
        text("让日常的截图，多一点乐趣。", 64, 1362, 840, 31, .semibold)
        text("macOS 14+   ·   Apple silicon / Intel   ·   本地处理，不上传剪贴板", 67, 1420, 830, 13, .regular, muted)
        text("好友试用版 · 未经苹果公证 · 首次打开与权限配置见使用说明", 67, 1455, 830, 11, .regular, color(0x898F9B))
        context.endPDFPage(); context.closePDF()
        print("Created promotional poster: 960 × 1520 points")
    }
}
