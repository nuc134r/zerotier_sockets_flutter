@DefaultAsset('package:zerotier_sockets/libzt.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'node.dart';

// Added to libzt by hook/patches/0002.
@Native<Int Function(Uint64, Pointer<Char>, UnsignedInt)>(symbol: 'zts_core_query_network')
external int _queryNetwork(int netId, Pointer<Char> dst, int len);

@Native<Int Function(Pointer<Char>, UnsignedInt)>(symbol: 'zts_core_query_peers')
external int _queryPeers(Pointer<Char> dst, int len);

// Added to libzt by hook/patches/0003.
@Native<Int Function(Pointer<Char>, UnsignedInt)>(symbol: 'zts_core_query_neighbors')
external int _queryNeighbors(Pointer<Char> dst, int len);

/// A member of a joined network this node exchanged IPv4 traffic with lately (the network stack's ARP
/// table, which forgets entries after a few minutes).
class ZeroTierNeighbor {
  const ZeroTierNeighbor({required this.networkId, required this.ip, required this.address});

  /// 16 hex digits.
  final String networkId;
  final String ip;

  /// The member's ZeroTier address (10 hex digits).
  final String address;

  @override
  bool operator ==(Object other) =>
      other is ZeroTierNeighbor && other.networkId == networkId && other.ip == ip && other.address == address;

  @override
  int get hashCode => Object.hash(networkId, ip, address);
}

/// Parses zts_core_query_neighbors's text.
List<ZeroTierNeighbor> parseNeighbors(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().split(' ') case [final nwid, final ip, final address] when nwid.length == 16 && address.length == 10)
          ZeroTierNeighbor(networkId: nwid, ip: ip, address: address),
    ];

/// The ZeroTier address inside an IPv6 address of network [networkId] (16 hex digits), when the network
/// uses ZeroTier's RFC4193 (`fd` + network id + `9993` + address) or 6PLANE (`fc` + folded network id +
/// address) scheme; null otherwise.
String? zeroTierAddressFromIp(String ip, String networkId) {
  final List<int> b;
  try {
    b = Uri.parseIPv6Address(ip.split('%').first);
  } on FormatException {
    return null;
  }
  final nwid = BigInt.tryParse(networkId, radix: 16);
  if (nwid == null) return null;
  String hex(Iterable<int> bytes) => [for (final x in bytes) x.toRadixString(16).padLeft(2, '0')].join();
  final idBytes = [for (var s = 56; s >= 0; s -= 8) ((nwid >> s) & BigInt.from(0xff)).toInt()];
  if (b[0] == 0xfd && hex(b.sublist(1, 9)) == hex(idBytes) && b[9] == 0x99 && b[10] == 0x93) {
    return hex(b.sublist(11, 16));
  }
  if (b[0] == 0xfc) {
    final folded = [for (var i = 0; i < 4; i++) idBytes[i] ^ idBytes[i + 4]];
    if (hex(b.sublist(1, 5)) == hex(folded)) return hex(b.sublist(5, 10));
  }
  return null;
}

/// A route the network's controller pushed.
class ZeroTierRoute {
  const ZeroTierRoute({required this.target, this.via, this.flags = 0, this.metric = 0});

  /// Address and prefix length, like `10.147.17.0/24`.
  final String target;

  /// The gateway; null for the network itself (reached directly).
  final String? via;
  final int flags;
  final int metric;

  @override
  bool operator ==(Object other) =>
      other is ZeroTierRoute && other.target == target && other.via == via && other.flags == flags && other.metric == metric;

  @override
  int get hashCode => Object.hash(target, via, flags, metric);

  @override
  String toString() => via == null ? target : '$target via $via';
}

enum ZeroTierNetworkType { private, public, unknown }

/// Everything libzt knows about a joined network.
class ZeroTierNetworkDetails {
  const ZeroTierNetworkDetails({
    required this.state,
    this.type = ZeroTierNetworkType.unknown,
    this.mac,
    this.mtu,
    this.broadcast,
    this.addresses = const [],
    this.routes = const [],
  });

  final ZeroTierNetworkState state;
  final ZeroTierNetworkType type;

  /// This node's Ethernet address in the network, like `5e:12:34:56:78:9a`.
  final String? mac;
  final int? mtu;
  final bool? broadcast;

  /// Every address assigned to this node, with its prefix length (`10.147.17.5/24`).
  final List<String> addresses;
  final List<ZeroTierRoute> routes;
}

enum ZeroTierPeerRole {
  leaf,
  moon,
  planet,
  unknown;

  static ZeroTierPeerRole of(int code) => switch (code) {
        0 => leaf,
        1 => moon,
        2 => planet,
        _ => unknown,
      };
}

/// A physical path to a peer.
class ZeroTierPath {
  const ZeroTierPath(this.address, {this.preferred = false});

  /// IP address and UDP port, like `192.0.2.7/9993`.
  final String address;
  final bool preferred;

  @override
  bool operator ==(Object other) => other is ZeroTierPath && other.address == address && other.preferred == preferred;

  @override
  int get hashCode => Object.hash(address, preferred);
}

/// Another ZeroTier node this one talks to: a root server (planet or moon) or a member of a network.
class ZeroTierPeer {
  const ZeroTierPeer({required this.address, required this.role, this.latency, this.version, this.paths = const []});

  /// 10 hex digits.
  final String address;
  final ZeroTierPeerRole role;

  /// Milliseconds; null when unknown.
  final int? latency;

  /// Like `1.14.2`; null when unknown.
  final String? version;

  /// Live paths; none means the traffic is relayed through a root.
  final List<ZeroTierPath> paths;

  bool get direct => paths.isNotEmpty;
}

/// Parses zts_core_query_network's text.
(List<String>, List<ZeroTierRoute>) parseNetworkDetails(String text) {
  final addresses = <String>[];
  final routes = <ZeroTierRoute>[];
  for (final line in text.split('\n')) {
    final f = line.trim().split(' ');
    if (f.length >= 2 && f[0] == 'addr') addresses.add(f[1]);
    if (f.length >= 5 && f[0] == 'route') {
      routes.add(ZeroTierRoute(
        target: f[1],
        via: f[2] == '-' ? null : f[2],
        flags: int.tryParse(f[3]) ?? 0,
        metric: int.tryParse(f[4]) ?? 0,
      ));
    }
  }
  // IPv4 first, as elsewhere.
  int v6(String a) => a.contains(':') ? 1 : 0;
  addresses.sort((a, b) => v6(a) - v6(b));
  return (addresses, routes);
}

/// Parses zts_core_query_peers's text.
List<ZeroTierPeer> parsePeers(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().split(' ') case [final address, final role, final latency, final version, ...final paths]
            when address.length == 10)
          ZeroTierPeer(
            address: address,
            role: ZeroTierPeerRole.of(int.tryParse(role) ?? -1),
            latency: switch (int.tryParse(latency)) { final l? when l >= 0 => l, _ => null },
            version: version.startsWith('-') ? null : version,
            paths: [
              for (final p in paths)
                if (p.isNotEmpty) ZeroTierPath(p.endsWith('*') ? p.substring(0, p.length - 1) : p, preferred: p.endsWith('*')),
            ],
          ),
    ];

String _hex2(int b) => b.toRadixString(16).padLeft(2, '0');

extension ZeroTierNodeDetails on ZeroTierNode {
  /// The UDP port the node listens on; null when it is not running.
  int? get port {
    if (!running) return null;
    final p = zts_node_get_port();
    return p > 0 ? p : null;
  }

  /// Details of a joined network: addresses with prefix lengths, routes, MAC, MTU.
  ZeroTierNetworkDetails details(BigInt id) {
    final state = network(id);
    if (!running) return ZeroTierNetworkDetails(state: state);
    final n = id.toUnsigned(64).toSigned(64).toInt();
    final text = _query((p, len) => _queryNetwork(n, p, len));
    final (addresses, routes) = parseNetworkDetails(text ?? '');
    final mac = zts_net_get_mac(n);
    final mtu = zts_net_get_mtu(n);
    final broadcast = zts_net_get_broadcast(n);
    return ZeroTierNetworkDetails(
      state: state,
      type: switch (zts_net_get_type(n)) {
        0 => ZeroTierNetworkType.private,
        1 => ZeroTierNetworkType.public,
        _ => ZeroTierNetworkType.unknown,
      },
      // An error comes back as a negative number.
      mac: mac <= 0 ? null : [for (var s = 40; s >= 0; s -= 8) _hex2((mac >> s) & 0xff)].join(':'),
      mtu: mtu > 0 ? mtu : null,
      broadcast: broadcast < 0 ? null : broadcast == 1,
      addresses: addresses.isEmpty ? state.addresses : addresses,
      routes: routes,
    );
  }

  /// Members of joined networks this node talked to lately over IPv4, with their ZeroTier addresses.
  List<ZeroTierNeighbor> neighbors() {
    if (!running) return const [];
    return parseNeighbors(_query(_queryNeighbors) ?? '');
  }

  /// The peers the node knows (roots and network members), with their paths.
  List<ZeroTierPeer> peers() {
    if (!running) return const [];
    return parsePeers(_query(_queryPeers) ?? '');
  }
}

/// Calls a text query, growing the buffer until the whole text fits.
String? _query(int Function(Pointer<Char> p, int len) read) {
  var size = 8192;
  for (var attempt = 0; attempt < 4; attempt++) {
    final p = calloc<Char>(size);
    try {
      final n = read(p, size);
      if (n < 0) return null;
      if (n < size) return p.cast<Utf8>().toDartString();
      size = n + 1;
    } finally {
      calloc.free(p);
    }
  }
  return null;
}
