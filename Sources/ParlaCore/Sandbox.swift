import Foundation

/// Whether this process is running inside an App Sandbox container.
///
/// The Mac App Store requires the sandbox, and two of this app's features cannot survive it: synthesizing a ⌘V
/// into another app needs Accessibility, which a sandboxed app is not granted; and `parla://transcribe?path=…`
/// rebuilds a URL from a string, which carries no sandbox extension, so the app may not open it however real
/// the file is.
///
/// The point of detecting it at RUNTIME rather than at compile time is that one binary then behaves honestly in
/// both worlds: the open-source build keeps the features, and the store build declines them out loud instead of
/// appearing to work and doing nothing. A silent no-op is the worst of the three outcomes — worse than the
/// feature being absent, because the user cannot tell the difference between "broken" and "I did it wrong".
///
/// `APP_SANDBOX_CONTAINER_ID` is the documented marker; it is present only when the process is containerised.
public enum Sandbox {
    public static let isActive: Bool = {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }()
}
