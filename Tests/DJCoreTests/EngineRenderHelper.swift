@preconcurrency import AVFoundation

@testable import DJCore

/// Pull `cycles` render cycles of `frames` frames through an offline engine on this thread, the
/// way the audio thread is pulled: source-node blocks, the frame clock, the output unit's
/// render notification (the master tap) and AVAudioEngine's own bookkeeping, nothing else.
/// The buffer is allocated by the caller of `makeEngineRenderBuffer`, outside any measured region.
func makeEngineRenderBuffer(_ dj: DJEngine, frames: Int) -> AVAudioPCMBuffer {
  AVAudioPCMBuffer(
    pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames))!
}

func pullEngine(_ dj: DJEngine, _ buffer: AVAudioPCMBuffer, cycles: Int, frames: Int) {
  for _ in 0..<cycles {
    _ = try? dj.engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
  }
}
