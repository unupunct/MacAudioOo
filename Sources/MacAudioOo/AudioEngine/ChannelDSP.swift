import Foundation

/// Per-channel effect parameters that the UI writes and the render thread reads.
struct ChannelFXParams {
    var comp = CompressorParams()
    var reverbSend: Float = 0     // linear, post-fader
    var delaySend: Float = 0      // linear, post-fader
}

/// Everything the render thread needs for one channel's processing chain
/// (EQ → compressor → fader → sends). Lives as long as the channel; sample-rate dependent
/// state is reconfigured when the output rate changes.
final class ChannelDSP {
    let eq: EQProcessor
    let fx: UnsafeMutablePointer<ChannelFXParams>
    var compressor = Compressor()          // render-thread state

    init(sampleRate: Double) {
        eq = EQProcessor(sampleRate: sampleRate)
        fx = .allocate(capacity: 1); fx.initialize(to: ChannelFXParams())
    }
    deinit { fx.deallocate() }
}
