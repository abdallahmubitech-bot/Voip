import 'dart:typed_data';

import '../../../../core/utils/constants.dart';

/// Re-frames an arbitrary PCM byte stream into fixed 40 ms packets.
///
/// The native recorder hands us whatever block size it feels like (often 512 or
/// 1024 bytes); the wire protocol needs exactly [frameSizeBytes]. Leftover bytes
/// are carried over, and if the backlog ever exceeds [maxPendingBytes] the
/// oldest audio is discarded so latency cannot grow without bound.
class PcmChunker {
  PcmChunker({
    this.frameSizeBytes = AudioConstants.bytesPerFrame,
    this.maxPendingBytes = AudioConstants.maxOutboundBacklogBytes,
  }) : assert(frameSizeBytes > 0 && frameSizeBytes.isEven);

  final int frameSizeBytes;
  final int maxPendingBytes;

  final BytesBuilder _pending = BytesBuilder(copy: true);

  int get pendingBytes => _pending.length;

  int _droppedBytes = 0;

  /// Total bytes thrown away by overflow protection (diagnostics).
  int get droppedBytes => _droppedBytes;

  List<Uint8List> add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return const <Uint8List>[];
    }
    _pending.add(chunk);

    var buffer = _pending.takeBytes();
    if (buffer.length > maxPendingBytes) {
      // Drop whole frames from the front (keeping sample alignment) until the
      // backlog fits: a stale backlog is worse than a small audio gap.
      var dropBytes = 0;
      while (buffer.length - dropBytes > maxPendingBytes) {
        dropBytes += frameSizeBytes;
      }
      _droppedBytes += dropBytes;
      buffer = Uint8List.sublistView(buffer, dropBytes);
    }

    final frames = <Uint8List>[];
    var offset = 0;
    while (buffer.length - offset >= frameSizeBytes) {
      frames.add(
        Uint8List.fromList(
          Uint8List.sublistView(buffer, offset, offset + frameSizeBytes),
        ),
      );
      offset += frameSizeBytes;
    }
    if (offset < buffer.length) {
      _pending.add(Uint8List.sublistView(buffer, offset));
    }
    return frames;
  }

  /// Discards partial audio — call this when the peer changes or the call ends.
  void reset() {
    _pending.clear();
    _droppedBytes = 0;
  }
}
