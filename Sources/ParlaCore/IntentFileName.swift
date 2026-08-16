import Foundation

/// A Shortcut hands us a filename, and we write a file with it. That name is INPUT, not a label.
///
/// `appendingPathComponent` does not resolve `..` — the filesystem does, at write time — so a Shortcut
/// supplying `../../../etc/passwd` escaped the temporary directory and wrote wherever the app could reach.
/// On iOS that is bounded by the container but not blocked: `../Library/Application Support/<bundle-id>/
/// history.json` resolves INSIDE the container and overwrites the user's entire archive.
///
/// This lives in Core because the same intent exists in both apps, and the first fix landed in the macOS copy
/// only — same defect, same day, half fixed. A sanitiser that one platform can forget to call is not one.
public enum IntentFileName {

    /// Reduce whatever arrives to a single, harmless path component.
    public static func safe(_ raw: String) -> String {
        // Collapses any directory structure, including `..` segments and absolute paths…
        var name = (raw as NSString).lastPathComponent
        // …but not always: for "/" and "//" it hands back "/" itself.
        name = name.replacingOccurrences(of: "/", with: "")
        // A colon is a path separator to some layers; a null byte truncates C strings.
        name = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\0", with: "")
        // EVERY leading dot, not one. Stripping a single dot turned "..." back into "..", which addresses the
        // PARENT directory — the escape the earlier explicit ".." check was supposed to have already ruled out,
        // reintroduced two lines later. Found by running the function, not by reading it.
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "parla-intent-\(UUID().uuidString)" : name
    }
}
