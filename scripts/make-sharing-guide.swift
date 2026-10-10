import AppKit
import CoreGraphics

// Native typography preserves Apple's system font and embedded Chinese glyphs.
@main
struct SharingGuide {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width: CGFloat = 960, margin: CGFloat = 64, gap: CGFloat = 24
        let column: CGFloat = (width - margin * 2 - gap) / 2
        let ink = NSColor(calibratedWhite: 0.10, alpha: 1)
        let secondary = NSColor(calibratedWhite: 0.37, alpha: 1)
        let blue = NSColor(calibratedRed: 0.04, green: 0.39, blue: 0.84, alpha: 1)
        let pale = NSColor(calibratedWhite: 0.965, alpha: 1)
        var drawings: [() -> Void] = []
        var allText: [String] = []
        func attributed(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = size >= 30 ? 0 : 5
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color ?? ink, .paragraphStyle: paragraph])
        }
        func layout(_ value: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer, NSRange, CGFloat) {
            let storage = NSTextStorage(attributedString: value)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: 10000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let range = manager.glyphRange(for: container)
            return (storage, manager, container, range, ceil(manager.usedRect(for: container).maxY) + 3)
        }
        @discardableResult func text(_ string: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 16,
                                    weight: NSFont.Weight = .regular, color: NSColor? = nil) -> CGFloat {
            let value = attributed(string, size: size, weight: weight, color: color)
            let (storage, manager, container, range, h) = layout(value, width: w)
            drawings.append {
                _ = storage; _ = container
                manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: x, y: y))
            }
            allText.append(string)
            return h
        }
        func rounded(_ rect: CGRect, color: NSColor, radius: CGFloat = 22) {
            drawings.append { color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill() }
        }
        func rule(_ y: CGFloat) {
            drawings.append {
                NSColor(calibratedWhite: 0.87, alpha: 1).setStroke()
                let path = NSBezierPath(); path.lineWidth = 0.7
                path.move(to: CGPoint(x: margin, y: y)); path.line(to: CGPoint(x: width - margin, y: y)); path.stroke()
            }
        }
        func section(_ number: String, _ title: String, at y: CGFloat, caption: String? = nil) -> CGFloat {
            rule(y)
            text(number, x: margin, y: y + 22, w: 35, size: 15, weight: .semibold, color: blue)
            text(title, x: margin + 45, y: y + 15, w: 550, size: 27, weight: .semibold)
            if let caption { text(caption, x: width - margin - 220, y: y + 25, w: 220, size: 12, color: secondary) }
            return y + 66
        }
        func card(_ title: String, _ body: String, x: CGFloat, y: CGFloat, w: CGFloat, label: String? = nil) -> CGFloat {
            let heading = attributed(title, size: 20, weight: .semibold)
            let value = attributed(body, size: 15.5, color: secondary)
            let headingH = layout(heading, width: w - 48).4
            let bodyH = layout(value, width: w - 48).4
            let h = 48 + headingH + 12 + bodyH + (label == nil ? 0 : 24)
            rounded(CGRect(x: x, y: y, width: w, height: h), color: pale)
            var top = y + 24
            if let label { text(label, x: x + 24, y: top, w: w - 48, size: 12, weight: .semibold, color: blue); top += 24 }
            text(title, x: x + 24, y: top, w: w - 48, size: 20, weight: .semibold)
            text(body, x: x + 24, y: top + headingH + 12, w: w - 48, size: 15.5, color: secondary)
            return h
        }
        func item(_ title: String, _ body: String, x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
            let headingH = text(title, x: x, y: y, w: w, size: 20, weight: .semibold)
            let bodyH = text(body, x: x, y: y + headingH + 8, w: w, size: 15.5, color: secondary)
            return headingH + bodyH + 32
        }

        text("CLIPLINE  /  0.1.15", x: margin, y: 54, w: 500, size: 14, weight: .semibold, color: secondary)
        text("把截图，挂起来。", x: margin - 2, y: 92, w: 730, size: 56, weight: .semibold)
        text("截图与录屏 · 剪贴板历史 · 图片编辑 · 喜欢的照片", x: margin, y: 173, w: 720, size: 19, color: secondary)
        text("macOS 14+     Apple silicon / Intel     本地运行，无需额外安装运行环境", x: margin, y: 210, w: 820, size: 13, color: secondary)
        let icon = NSImage(contentsOfFile: "build/clipline-icon-preview.png")!
        drawings.append { icon.draw(in: CGRect(x: 782, y: 54, width: 114, height: 114), from: .zero, operation: .sourceOver,
                                     fraction: 1, respectFlipped: true, hints: nil) }
        // Deliberately illustrative cards: no user's private screenshots or paths.
        drawings.append {
            let line = NSBezierPath(); line.lineWidth = 1.4
            secondary.withAlphaComponent(0.45).setStroke()
            line.move(to: CGPoint(x: margin, y: 258))
            line.curve(to: CGPoint(x: width - margin, y: 258), controlPoint1: CGPoint(x: 360, y: 286), controlPoint2: CGPoint(x: 600, y: 286))
            line.stroke()
        }
        for (x, title, sub, tint) in [(CGFloat(130), "截图", "灵感，一眼可见。", NSColor(calibratedRed: 0.87, green: 0.95, blue: 0.95, alpha: 1)),
                                      (CGFloat(393), "剪贴板", "文字与图片，随手找回。", pale),
                                      (CGFloat(656), "录屏", "悬停，静音预览。", NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.99, alpha: 1))] {
            rounded(CGRect(x: x, y: 276, width: 174, height: 86), color: tint, radius: 16)
            rounded(CGRect(x: x + 83, y: 263, width: 8, height: 25), color: ink, radius: 4)
            text(title, x: x + 16, y: 295, w: 145, size: 18, weight: .medium)
            text(sub, x: x + 16, y: 326, w: 152, size: 10.5, color: secondary)
        }

        var y = section("01", "第一次使用，先做好这四步。", at: 406)
        let right = margin + column + gap
        let install = card("解压，把应用放好。", "解压分享包，把 Clipline-0.1.15.app 拖入“应用程序”，再打开。它常驻菜单栏；点击晾绳图标进入“设置…”。请只运行一个版本。\n\n此分享版尚未经过苹果公证。若提示无法验证开发者：确认来源可信后，到“系统设置 → 隐私与安全性 → 仍要打开”。若系统提示恶意软件或会损坏电脑，请停止打开并联系发送者。", x: margin, y: y, w: column, label: "STEP 1  /  安装与首次打开")
        let permission = card("授权的是你正在运行的应用。", "Clipline“设置… → 打开设置…”，进入系统“隐私与安全性 → 辅助功能”，用 + 添加当前应用并启用。\n\n展开“确认授权的是当前应用”，点“在访达中显示当前应用”定位它。每个人的路径不同，不要照抄他人的路径；旧版授权也不一定适用新版。\n\n返回 Clipline，确认“辅助功能权限已生效”。关闭设置窗口后，再测试菜单栏双击。", x: right, y: y, w: column, label: "STEP 2  /  辅助功能")
        y += max(install, permission) + 20
        let instant = card("勾选“接管系统截图”。", "确认出现“即时截图已开启，系统浮动缩略图已关闭”。这样截图不会先在右下角停留，挂入更连贯。\n\n关闭接管或正常退出时，会恢复原来的浮动缩略图设置。接管开关本身不会修改你选好的保存目录。", x: margin, y: y, w: column, label: "STEP 3  /  即时截图")
        let folder = card("保存目录，由你决定。", "按 ⌘⇧5 → 选项 → 存储到，选择自己的目录。晾绳会跟随目录变化，旧文件留在原处，固定照片保持不变。\n\n“恢复默认位置并开启即时截图”会主动改为你自己的“图片 / Clipline Screenshots”文件夹。这个按钮不是必须点击。", x: right, y: y, w: column, label: "STEP 4  /  截图与录屏位置")
        y += max(instant, folder) + 40

        y = section("02", "日常操作，一看就会。", at: y)
        let daily: [(String, String, String, String)] = [
            ("展开与收起", "双击菜单栏真正的空白处，或按 Control + Option + T。全屏时先让菜单栏显示；设置或编辑窗口打开时暂停展开。移出晾绳约 0.5 秒后自动收起。", "剪贴板历史", "复制文字或图片后自动记录，最多最近 100 条，相同内容合并。Control + Option + V 打开历史；单击卡片重新复制，再到目标应用按 ⌘V 粘贴。"),
            ("横向浏览与复制", "⌘⇧3 截全屏，⌘⇧4 截选区，新截图自动挂入。触控板左右滑动，或 Shift + 鼠标滚轮。单击截图复制，再到目标应用按 ⌘V。菜单“显示切换栏”可隐藏底部分页；隐藏后仍能用菜单切换。", "暂停、删除与清空", "菜单可暂停或继续剪贴板记录；暂停期间不会记录，恢复时不补录。剪贴板卡片的叉号只移除这条历史；设置里可清空全部历史。退出应用会清空剪贴板历史。"),
            ("录屏也能挂在绳子上", "按 ⌘⇧5 使用 macOS 系统录屏，停止并保存后上绳。悬停时静音播放，移开就停止；同一时间只预览一个视频。单击复制文件；长按或“打开”使用默认视频播放器。", "取下和删除，是两件事", "截图 / 录屏卡片的叉号：原文件移到系统废纸篓。菜单“取下”及设置“移除全部截图”只移除卡片，保留原文件。超过 100 张时淘汰旧卡片，也不删除文件。")
        ]
        for (leftTitle, leftBody, rightTitle, rightBody) in daily {
            let a = item(leftTitle, leftBody, x: margin, y: y, w: column)
            let b = item(rightTitle, rightBody, x: right, y: y, w: column)
            y += max(a, b)
        }
        y += 8

        y = section("03", "编辑截图，也挂上你喜欢的照片。", at: y)
        let edit = card("内置编辑，系统预览也保留。", "长按图片约 0.45 秒，或右键 / 双击图片 →“编辑图片”。想用 macOS“预览”？图片菜单选“打开”。\n\n画笔、荧光笔、文字、箭头、框线、椭圆、马赛克、遮盖、橡皮擦；支持撤销、重做、重置，… 菜单可旋转和翻转。\n\n裁切预设先生成选框。拖动选框选择区域，比例框可拖动四角缩放，固定像素框仅移动；点“应用裁切”才生效。Return 确认，Esc 取消。\n\n“复制”导出编辑结果；“保存”生成 PNG 副本、保留原图，… →“另存为…”可换目录。关闭窗口前记得保存。", x: margin, y: y, w: column)
        let pins = card("把喜欢的照片，固定在这里。", "截图图片菜单 →“在此位置固定图片 → 选择图片…”，从自己的文件夹挑一张照片。固定位置就是这张截图卡片目前的位置。\n\n固定照片支持左右拖动，也能通过菜单放到左端、中央、右端；可更换或取消固定。黑色夹子帮助区分固定照片。\n\n固定数量受屏幕宽度限制，位置和照片会跨启动保留。取消固定只移除软件保存的副本，不删除你选中的原照片。\n\n截图会从固定照片背后滚过；固定照片可能挡住截图，请按自己的喜好安排位置与数量。", x: right, y: y, w: column)
        y += max(edit, pins) + 40

        y = section("04", "记住这些，使用更顺手。", at: y)
        let notes = "• 找不到剪贴板历史？先检查是否暂停记录；只记录启动后新复制的文字与图片，不会自动粘贴，也不支持文件列表或跨设备同步。大图片较多时，受内存预算限制，历史可能少于 100 条。\n• 看不到新截图？检查设置里显示的当前保存目录，确认文件已生成，并按系统提示允许目录访问；仅查看目录本层，不递归子文件夹。\n• 双击没反应？确认是菜单栏空白处，不是菜单项、状态图标或浏览器页签；先关闭设置 / 编辑窗口。升级后如权限仍未生效，移除旧授权记录，再添加正在运行的版本。\n• 菜单“设置…”还能调整音效、登录时启动和语言（简体 / 繁体 / English / Español）。\n• 本地处理，不上传剪贴板。退出会清空剪贴板历史，截图原文件与固定照片保留。企业管理设备可能限制安装或授权，请遵循单位的管理要求。"
        y += text(notes, x: margin, y: y, w: width - margin * 2, size: 14.5, color: secondary) + 28
        rule(y)
        y += 22
        y += text("好友试用版 · 未经苹果公证 · macOS 14 及更新系统 · Apple silicon / Intel 通用包", x: margin, y: y, w: width - margin * 2, size: 13, weight: .medium) + 10
        y += text("已在 Apple silicon / macOS 14.7.4 检查；其他机型与系统版本尚未逐一实机验证。无需 Codex、Swift、Python、Homebrew 或开发工具。", x: margin, y: y, w: width - margin * 2, size: 12, color: secondary) + 12
        y += text("先配置辅助功能，再开始双击菜单栏空白处。", x: margin, y: y, w: width - margin * 2, size: 11, color: secondary) + 12
        y += text("基于 Alejandro Buján 的 Tendedero（MIT）改造  /  使用说明 0.1.15  /  2026.10.10", x: margin, y: y, w: width - margin * 2, size: 10.5, color: secondary) + 44
        let height = ceil(y)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, [kCGPDFContextTitle as String: "Clipline 0.1.15 使用说明", kCGPDFContextAuthor as String: "Clipline"] as CFDictionary) else { fatalError("Cannot create PDF") }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
        for draw in drawings { draw() }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try allText.joined(separator: "\n\n").write(to: output.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        print("Created one-page guide: \(Int(width)) × \(Int(height)) points")
    }
}
