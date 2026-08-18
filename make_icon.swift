import AppKit
import Foundation

// Rasterises the app icon from the project's own artwork.
//
// It used to DRAW one: a purple gradient with SF Symbols' `waveform` composited on top. That cannot ship.
// Apple's SF Symbols licence agreement forbids using the symbols — or anything confusingly similar to them —
// in an app icon, which makes it an App Review rejection rather than a matter of taste. The real artwork has
// existed in this repo since July and iOS has been shipping it all along; only macOS was still drawing its own.
//
// The master is the 1024×1024 PNG inside the iOS asset catalogue, deliberately rather than a second copy here:
// an asset catalogue needs the file physically in place, so making that the single source means both platforms
// are provably shipping the SAME icon instead of two things that merely look alike.

let master = "apps/ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("❌ icon: \(message)\n".utf8))
    exit(1)
}

guard FileManager.default.fileExists(atPath: master) else {
    // Loud, not silent. A macOS build with no icon is a rejection, and the old script swallowed every failure.
    die("master artwork missing at \(master) — run from the repo root")
}
guard let image = NSImage(contentsOfFile: master), image.size.width > 0 else {
    die("could not read \(master)")
}
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    die("could not re-encode the artwork")
}
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { die("\(error)") }
print("icon: \(outPath) (from \(master))")
