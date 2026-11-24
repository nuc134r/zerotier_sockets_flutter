@DefaultAsset('package:zerotier_sockets/libzt.dart')
library;

import 'dart:ffi';


import 'native.dart';
import 'node.dart';

// Added to libzt by hook/patches/0005.
@Native<Int Function(Pointer<Char>, UnsignedShort)>(symbol: 'zts_core_set_udp_relay')
external int _setUdpRelay(Pointer<Char> ip, int port);

/// Where the node's own UDP traffic (to roots and peers) goes: see [ZeroTierNodeRelay.udpRelay].
sealed class ZeroTierUdpRelay {
  const ZeroTierUdpRelay();

  /// Through the relay a SOCKS5 server gave for a UDP ASSOCIATE (`BND.ADDR` and `BND.PORT` of its
  /// reply; when the server answers `0.0.0.0`, its own address). The association lasts while its TCP
  /// connection is open: keeping it open is the caller's job.
  const factory ZeroTierUdpRelay.socks5(String ip, int port) = ZeroTierSocks5Relay;

  /// Nothing goes out and nothing is taken, until another relay is set: for the time a lost association
  /// is being made again, so that no packet leaves directly meanwhile.
  static const hold = ZeroTierUdpHold._();
}

class ZeroTierSocks5Relay extends ZeroTierUdpRelay {
  const ZeroTierSocks5Relay(this.ip, this.port);

  /// An IPv4 or IPv6 address (not a host name).
  final String ip;
  final int port;

  @override
  bool operator ==(Object other) => other is ZeroTierSocks5Relay && other.ip == ip && other.port == port;

  @override
  int get hashCode => Object.hash(ip, port);

  @override
  String toString() => 'ZeroTierUdpRelay.socks5($ip, $port)';
}

class ZeroTierUdpHold extends ZeroTierUdpRelay {
  const ZeroTierUdpHold._();

  @override
  String toString() => 'ZeroTierUdpRelay.hold';
}

ZeroTierUdpRelay? _relay;

extension ZeroTierNodeRelay on ZeroTierNode {
  /// Where the node's UDP traffic goes; null (the default): directly.
  ///
  /// Through a SOCKS5 relay every ZeroTier packet is wrapped in a SOCKS5 UDP request header and sent to
  /// the relay, only datagrams from the relay are taken, and the device's own addresses are not offered
  /// to peers as direct paths. It applies at once, to a running node too, and stays set across
  /// stop/start. Traffic inside the networks (sockets of this package) is unchanged: it rides on it.
  ZeroTierUdpRelay? get udpRelay => _relay;

  set udpRelay(ZeroTierUdpRelay? relay) {
    switch (relay) {
      case null:
        check(_setUdpRelay(nullptr, 0), 'set_udp_relay');
      case ZeroTierUdpHold():
        check(withCString('', (p) => _setUdpRelay(p, 0)), 'set_udp_relay');
      case ZeroTierSocks5Relay(:final ip, :final port):
        if (port < 1 || port > 65535) throw ZeroTierException('Not a port: $port');
        final r = withCString(ip, (p) => _setUdpRelay(p, port));
        if (r < 0) throw ZeroTierException('Not an IP address: $ip', code: r);
    }
    _relay = relay;
  }
}
