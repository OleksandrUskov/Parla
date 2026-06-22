import AppKit

// Генерит 1024×1024 PNG иконки: фиолетовый градиент + белая «waveform».
_ = NSApplication.shared

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size: CGFloat = 1024

func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    image.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: size * 0.224, yRadius: size * 0.224).addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.46, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.58, green: 0.30, blue: 0.92, alpha: 1),
])!.draw(in: rect, angle: -90)

if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil),
   let configured = sym.withSymbolConfiguration(.init(pointSize: size * 0.5, weight: .semibold)) {
    let white = tint(configured, .white)
    let s = size * 0.5
    let dx = (size - s) / 2
    white.draw(in: NSRect(x: dx, y: dx, width: s, height: s))
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon: \(outPath)")
