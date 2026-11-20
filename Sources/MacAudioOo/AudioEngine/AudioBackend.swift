import Foundation

/// Common interface implemented by each OS-specific capture backend.
/// Phase 2 adds CoreAudioTapBackend, ScreenCaptureKitBackend and
/// VirtualAudioDriverBackend conforming to this.
protocol AudioBackend: AnyObject {
    var capability: BackendCapability { get }
    func start() throws
    func stop()
}
