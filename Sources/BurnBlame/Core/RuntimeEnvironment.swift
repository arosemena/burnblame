import Foundation

/// Detects whether BurnBlame is running inside the Mac App Store App Sandbox.
/// Allows the exact same codebase to ship both as a full-featured notarized Direct/Homebrew build
/// and as a clean, App-Store-compliant Sandboxed build without triggering sandbox violation logs.
public enum RuntimeEnvironment {
    public static var isSandboxed: Bool {
        #if APP_STORE
        return true
        #else
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #endif
    }
}
