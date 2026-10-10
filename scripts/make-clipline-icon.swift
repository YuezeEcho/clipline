import AppKit

@main
struct MakeCliplineIcon {
    static func main() throws {
        let image = CliplineIcon.applicationImage()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        // Also retain a magnified template preview for visual inspection.
        if CommandLine.arguments.count > 2 {
            let menu = CliplineIcon.menuBarImage()
            let preview = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { _ in
                NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 180, height: 180).fill()
                menu.draw(in: CGRect(x: 0, y: 0, width: 180, height: 180))
                return true
            }
            let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
