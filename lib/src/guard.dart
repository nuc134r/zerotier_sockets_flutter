@DefaultAsset('package:zerotier_sockets/libzt.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Int Function(Pointer<Uint64>)>(symbol: 'zts_guard_stats')
external int _guardStats(Pointer<Uint64> out);

@Native<Void Function(Int)>(symbol: 'zts_guard_selftest')
external void _guardSelftest(int kind);

/// What libzt's guarded allocator holds (built with the `memory_guard` user define, see hook/build.dart).
class ZeroTierMemoryGuardStats {
  const ZeroTierMemoryGuardStats({
    required this.live,
    required this.liveBytes,
    required this.mappedBytes,
    required this.allocations,
    required this.fallbacks,
    required this.quarantined,
  });

  /// Allocations not freed yet, and the bytes they asked for.
  final int live;
  final int liveBytes;

  /// Memory mapped for them (each takes whole pages plus a guard page).
  final int mappedBytes;

  /// Allocations made so far.
  final int allocations;

  /// Allocations that went to the normal allocator (mmap failed or the cap was reached): unguarded.
  final int fallbacks;

  /// Freed allocations kept inaccessible, to catch late writes.
  final int quarantined;

  @override
  String toString() =>
      '$live live (${liveBytes >> 10} KB asked, ${mappedBytes >> 20} MB mapped), $allocations allocations, '
      '$fallbacks unguarded, $quarantined in quarantine';
}

/// libzt's guarded allocator, when libzt was built with it.
abstract final class ZeroTierMemoryGuard {
  /// The guard's numbers; null when libzt was built without it.
  static ZeroTierMemoryGuardStats? stats() {
    final out = calloc<Uint64>(6);
    try {
      _guardStats(out);
      return ZeroTierMemoryGuardStats(
        live: out[0],
        liveBytes: out[1],
        mappedBytes: out[2],
        allocations: out[3],
        fallbacks: out[4],
        quarantined: out[5],
      );
    } on ArgumentError {
      return null; // the symbol is not there: no guard
    } finally {
      calloc.free(out);
    }
  }

  /// Misuses a guarded allocation on purpose (1 overrun, 2 write after free, 3 double free): the process
  /// dies at once. Only for checking that the guard works.
  static void selftest(int kind) => _guardSelftest(kind);
}
