import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native.dart';

/// Where a joined network stands.
enum ZeroTierNetworkStatus {
  /// Waiting for the controller (also: not authorized yet on a private network).
  requestingConfiguration,
  ok,
  accessDenied,
  notFound,
  portError,
  clientTooOld,
  unknown;

  static ZeroTierNetworkStatus of(int code) => switch (code) {
        0 => requestingConfiguration,
        1 => ok,
        2 => accessDenied,
        3 => notFound,
        4 => portError,
        5 => clientTooOld,
        _ => unknown,
      };
}

class ZeroTierNetworkState {
  const ZeroTierNetworkState({required this.id, required this.status, required this.name, required this.addresses});

  final BigInt id;
  final ZeroTierNetworkStatus status;
  final String? name;

  /// Addresses this node got in the network (IPv4 first).
  final List<String> addresses;

  bool get ready => status == ZeroTierNetworkStatus.ok && addresses.isNotEmpty;

  String get idHex => id.toRadixString(16).padLeft(16, '0');
}

class ZeroTierNodeState {
  const ZeroTierNodeState({required this.running, required this.online, required this.nodeId, required this.networks});

  final bool running;
  final bool online;

  /// 10 hex digits, or null before the node started.
  final String? nodeId;
  final List<ZeroTierNetworkState> networks;
}

/// The ZeroTier node of this process (libzt runs one).
///
/// libzt reports events through a C callback whose message is freed when the callback returns, which
/// does not fit Dart's asynchronous native callbacks; [watch] polls instead.
class ZeroTierNode {
  ZeroTierNode._();

  static final instance = ZeroTierNode._();

  final Set<BigInt> _joined = {};
  bool _running = false;
  String? _storagePath;
  Future<void>? _stopping;

  bool get running => _running;

  bool get online => _running && zts_node_is_online() == 1;

  /// The node's identity is kept in [path] (created when missing). Call before [start]; it is applied
  /// again on every start (libzt forgets it when the node stops).
  void initStorage(String path) {
    check(withCString(path, zts_init_from_storage), 'init_from_storage');
    _storagePath = path;
  }

  /// Starts the node, after a previous [stop] has finished.
  Future<void> start() async {
    await _stopping;
    if (_running) return;
    final path = _storagePath;
    if (path != null) check(withCString(path, zts_init_from_storage), 'init_from_storage');
    check(zts_node_start(), 'node_start');
    _running = true;
  }

  /// Stops the node and forgets the joined networks. libzt tears the service down on its own thread,
  /// so the future completes a moment later; [start] waits for it (starting too early crashes libzt).
  Future<void> stop() {
    if (!_running) return _stopping ?? Future.value();
    _running = false;
    _joined.clear();
    return _stopping = _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    // Right after start the service thread may not be up yet.
    for (var i = 0; zts_node_stop() == zts_error_t.ZTS_ERR_SERVICE.value && i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 750));
  }

  /// 10 hex digits, or null while the identity is being generated.
  String? get nodeId {
    if (!_running) return null;
    final id = zts_node_get_id();
    return id <= 0 ? null : id.toRadixString(16).padLeft(10, '0');
  }

  void join(BigInt networkId) {
    check(zts_net_join(_u64(networkId)), 'net_join');
    _joined.add(networkId);
  }

  void leave(BigInt networkId) {
    zts_net_leave(_u64(networkId));
    _joined.remove(networkId);
  }

  Set<BigInt> get joined => Set.unmodifiable(_joined);

  ZeroTierNetworkState network(BigInt id) {
    final n = _u64(id);
    final status = zts_net_get_status(n);
    final name = _string(ZTS_MAX_NETWORK_SHORT_NAME_LENGTH + 1, (p, len) => zts_net_get_name(n, p, len));
    return ZeroTierNetworkState(
      id: id,
      status: status < 0 ? ZeroTierNetworkStatus.requestingConfiguration : ZeroTierNetworkStatus.of(status),
      name: name == null || name.isEmpty ? null : name,
      addresses: [
        for (final family in [ZTS_AF_INET, ZTS_AF_INET6])
          if (zts_addr_is_assigned(n, family) == 1) ?_string(ZTS_IP_MAX_STR_LEN, (p, len) => zts_addr_get_str(n, family, p, len)),
      ],
    );
  }

  ZeroTierNodeState get state => ZeroTierNodeState(
        running: _running,
        online: online,
        nodeId: nodeId,
        networks: [for (final id in _joined) network(id)],
      );

  /// The node's state every [interval] (only when it changed). Cancelling the subscription stops
  /// polling at once.
  Stream<ZeroTierNodeState> watch({Duration interval = const Duration(milliseconds: 500)}) {
    Timer? timer;
    String? last;
    late final StreamController<ZeroTierNodeState> controller;
    void poll() {
      final s = state;
      final key = '${s.running}${s.online}${s.nodeId}${[for (final n in s.networks) '${n.idHex}${n.status}${n.addresses}${n.name}']}';
      if (key != last) {
        last = key;
        controller.add(s);
      }
    }

    void resume() {
      poll();
      timer = Timer.periodic(interval, (_) => poll());
    }

    void pause() {
      timer?.cancel();
      timer = null;
    }

    controller = StreamController(onListen: resume, onResume: resume, onPause: pause, onCancel: pause);
    return controller.stream;
  }

  /// Waits until the node is online and [networkId] (if given) is ready.
  Future<void> waitUntilReady({BigInt? networkId, Duration timeout = const Duration(seconds: 60)}) async {
    final ready = Completer<void>();
    final sub = watch(interval: const Duration(milliseconds: 100)).listen((s) {
      if (!ready.isCompleted && s.online && (networkId == null || s.networks.any((n) => n.id == networkId && n.ready))) {
        ready.complete();
      }
    });
    try {
      await ready.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  static int _u64(BigInt id) => id.toUnsigned(64).toSigned(64).toInt();

  static String? _string(int size, int Function(Pointer<Char> p, int len) read) {
    final p = calloc<Char>(size);
    try {
      return read(p, size) < 0 ? null : p.cast<Utf8>().toDartString();
    } finally {
      calloc.free(p);
    }
  }
}

/// Parses a 16-hex-digit network id.
BigInt? parseNetworkId(String text) {
  final t = text.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(t)) return null;
  return BigInt.parse(t, radix: 16);
}
