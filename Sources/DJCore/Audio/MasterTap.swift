@preconcurrency import AVFoundation

extension DJEngine {
  /// Feed `masterTap` from the main mixer's output with `installTap`.
  ///
  /// **Which thread.** The block does not run on the render thread. AVFoundation copies the
  /// mixer's output into a buffer and calls the block from its own tap thread, so the
  /// copy into the ring happens there. That is acceptable because the render thread's
  /// cost is whatever AVFoundation does to hand the block over (measured: zero malloc/free
  /// per cycle, `ScopeTapRealTimeTests.realEngineMasterTapRenderDoesNotAllocate`), and the
  /// block itself only does a preallocated copy into the `AudioTap`. The ring stays
  /// single-producer: this block is the only writer of `masterTap`, and AVFoundation
  /// serialises its invocations. The price is latency of up to one tap buffer, which a
  /// scope view does not notice.
  ///
  /// (A custom `AUAudioUnit` hosted in an `AVAudioUnitEffect` in the master path, the first
  /// design, cost one malloc/free pair per render cycle even with an empty render block.)
  func installMasterTap() {
    let tap = masterTap
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      guard let ch = buffer.floatChannelData else { return }
      let n = Int(buffer.frameLength)
      tap.write(ch[0], buffer.format.channelCount > 1 ? ch[1] : nil, frames: n)
    }
  }
}
