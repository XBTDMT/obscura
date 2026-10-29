// ObscuraSupport — the ceilings on untrusted image input, in one place so every layer that reads an image (the folder
// watcher's container check, the codec, the engine) refuses at the same size (security scan F1, F11).

public enum InputLimits {
    /// Hard ceiling on encoded bytes read from disk or the pasteboard. No screenshot is this big; a file this size is a
    /// different kind of file, and the engine lists it "not checked" (too large) rather than reading it.
    public static let maxInputBytes = 512 * 1024 * 1024
    /// Hard ceiling on pixels decoded or rendered. A render context is 4 bytes per pixel, so 200 MP is about 800 MB;
    /// above it an image is refused as too large rather than risking a memory death.
    public static let maxPixels = 200_000_000
}
