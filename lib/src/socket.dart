import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native.dart';
import 'poller.dart';

const _readSize = 64 * 1024;

/// A TCP connection over a ZeroTier network. Mirrors `dart:io` sockets: [stream] for incoming bytes,
/// [sink] (or [add]) for outgoing ones.
class ZeroTierSocket {
  ZeroTierSocket._(this._fd, this.remoteAddress, this.remotePort) {
    _sinkSub = _sink.stream.listen(_write);
    Poller.instance.register(_fd, ZTS_POLLIN, _onPoll);
  }

  /// Connects to [address]:[port] (an IP inside a joined network).
  static Future<ZeroTierSocket> connect(String address, int port, {Duration timeout = const Duration(seconds: 10)}) async {
    final fd = check(zts_bsd_socket(familyOf(address), ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP), 'socket');
    try {
      check(zts_set_blocking(fd, 0), 'set_blocking');
      final (addr, len) = sockaddr(address, port);
      try {
        final r = zts_bsd_connect(fd, addr.cast(), len);
        if (r < 0 && !wouldBlock(zts_errno)) throw ZeroTierException('Cannot connect to $address:$port', code: r, errno: zts_errno);
      } finally {
        calloc.free(addr);
      }
      final connected = Completer<void>();
      Poller.instance.register(fd, ZTS_POLLOUT, (revents) {
        if (connected.isCompleted) return;
        final error = zts_get_last_socket_error(fd);
        if ((revents & (ZTS_POLLERR | ZTS_POLLHUP)) != 0 || error > 0) {
          connected.completeError(ZeroTierException('Cannot connect to $address:$port', errno: error));
        } else {
          connected.complete();
        }
      });
      try {
        await connected.future.timeout(timeout, onTimeout: () => throw ZeroTierException('Timed out connecting to $address:$port'));
      } finally {
        Poller.instance.unregister(fd);
      }
      return ZeroTierSocket._(fd, address, port);
    } catch (_) {
      zts_bsd_close(fd);
      rethrow;
    }
  }

  /// Wraps an accepted connection.
  factory ZeroTierSocket.fromAccepted(int fd, String address, int port) {
    zts_set_blocking(fd, 0);
    return ZeroTierSocket._(fd, address, port);
  }

  final int _fd;
  final String remoteAddress;
  final int remotePort;

  final _incoming = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();
  late final StreamSubscription<List<int>> _sinkSub;
  final _done = Completer<void>();
  final List<Uint8List> _pending = [];
  bool _closed = false;

  Stream<Uint8List> get stream => _incoming.stream;

  StreamSink<List<int>> get sink => _sink.sink;

  void add(List<int> data) => _write(data);

  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  void _onPoll(int revents) {
    if ((revents & ZTS_POLLIN) != 0) _read();
    if ((revents & ZTS_POLLOUT) != 0) _flush();
    if ((revents & (ZTS_POLLERR | ZTS_POLLHUP | ZTS_POLLNVAL)) != 0 && (revents & ZTS_POLLIN) == 0) destroy();
  }

  void _read() {
    final buf = calloc<Uint8>(_readSize);
    try {
      while (!_closed) {
        final n = zts_bsd_recv(_fd, buf.cast(), _readSize, 0);
        if (n > 0) {
          _incoming.add(copyBytes(buf, n));
        } else if (n == 0) {
          destroy(); // the other side closed
          return;
        } else {
          if (!wouldBlock(zts_errno)) destroy();
          return;
        }
      }
    } finally {
      calloc.free(buf);
    }
  }

  void _write(List<int> data) {
    if (_closed || data.isEmpty) return;
    _pending.add(data is Uint8List ? data : Uint8List.fromList(data));
    _flush();
  }

  void _flush() {
    while (_pending.isNotEmpty && !_closed) {
      final chunk = _pending.first;
      final buf = calloc<Uint8>(chunk.length);
      buf.asTypedList(chunk.length).setAll(0, chunk);
      final n = zts_bsd_send(_fd, buf.cast(), chunk.length, 0);
      calloc.free(buf);
      if (n < 0) {
        if (wouldBlock(zts_errno)) break;
        destroy();
        return;
      }
      if (n < chunk.length) {
        _pending[0] = Uint8List.sublistView(chunk, n);
        break;
      }
      _pending.removeAt(0);
    }
    Poller.instance.setEvents(_fd, _pending.isEmpty ? ZTS_POLLIN : ZTS_POLLIN | ZTS_POLLOUT);
  }

  /// Sends what is pending, then closes.
  Future<void> close() async {
    for (var i = 0; i < 200 && _pending.isNotEmpty && !_closed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    destroy();
    return done;
  }

  /// Closes now, dropping anything not sent.
  void destroy() {
    if (_closed) return;
    _closed = true;
    Poller.instance.unregister(_fd);
    zts_bsd_shutdown(_fd, ZTS_SHUT_RDWR);
    zts_bsd_close(_fd);
    _sinkSub.cancel();
    _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Accepts TCP connections on a ZeroTier address.
class ZeroTierServerSocket extends Stream<ZeroTierSocket> {
  ZeroTierServerSocket._(this._fd, this.address, this.port) {
    Poller.instance.register(_fd, ZTS_POLLIN, (_) => _accept());
  }

  /// Listens on [address] (`0.0.0.0` for every joined network) and [port].
  static ZeroTierServerSocket bind(String address, int port, {int backlog = 16}) {
    final fd = check(zts_bsd_socket(familyOf(address), ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP), 'socket');
    try {
      check(zts_set_blocking(fd, 0), 'set_blocking');
      final one = calloc<Int>()..value = 1;
      zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_REUSEADDR, one.cast(), sizeOf<Int>());
      calloc.free(one);
      final (addr, len) = sockaddr(address, port);
      try {
        check(zts_bsd_bind(fd, addr.cast(), len), 'Cannot listen on $address:$port');
      } finally {
        calloc.free(addr);
      }
      check(zts_bsd_listen(fd, backlog), 'listen');
      return ZeroTierServerSocket._(fd, address, port);
    } catch (_) {
      zts_bsd_close(fd);
      rethrow;
    }
  }

  final int _fd;
  final String address;
  final int port;
  final _connections = StreamController<ZeroTierSocket>();

  void _accept() {
    final addr = calloc<zts_sockaddr_storage>();
    final len = calloc<Uint32>();
    try {
      while (true) {
        len.value = sizeOf<zts_sockaddr_storage>();
        final fd = zts_bsd_accept(_fd, addr.cast(), len);
        if (fd < 0) return;
        final (ip, port) = sockaddrToString(addr.cast(), len.value);
        _connections.add(ZeroTierSocket.fromAccepted(fd, ip, port));
      }
    } finally {
      calloc.free(addr);
      calloc.free(len);
    }
  }

  @override
  StreamSubscription<ZeroTierSocket> listen(void Function(ZeroTierSocket)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _connections.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  void close() {
    Poller.instance.unregister(_fd);
    zts_bsd_close(_fd);
    _connections.close();
  }
}

/// A received UDP packet.
class ZeroTierDatagram {
  const ZeroTierDatagram(this.data, this.address, this.port);

  final Uint8List data;
  final String address;
  final int port;
}

/// UDP over ZeroTier, like `RawDatagramSocket`.
class ZeroTierDatagramSocket extends Stream<ZeroTierDatagram> {
  ZeroTierDatagramSocket._(this._fd, this.address, this.port) {
    Poller.instance.register(_fd, ZTS_POLLIN, (_) => _receive());
  }

  /// Binds to [address] (`0.0.0.0` for any) and [port] (0 picks one).
  static ZeroTierDatagramSocket bind(String address, int port) {
    final fd = check(zts_bsd_socket(familyOf(address), ZTS_SOCK_DGRAM, ZTS_IPPROTO_UDP), 'socket');
    try {
      check(zts_set_blocking(fd, 0), 'set_blocking');
      final (addr, len) = sockaddr(address, port);
      try {
        check(zts_bsd_bind(fd, addr.cast(), len), 'Cannot bind UDP $address:$port');
      } finally {
        calloc.free(addr);
      }
      return ZeroTierDatagramSocket._(fd, address, port);
    } catch (_) {
      zts_bsd_close(fd);
      rethrow;
    }
  }

  final int _fd;
  final String address;
  final int port;
  final _packets = StreamController<ZeroTierDatagram>();

  /// Sends one packet; returns the bytes sent (0 if it would block).
  int send(List<int> data, String toAddress, int toPort) {
    final (addr, len) = sockaddr(toAddress, toPort);
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      final n = zts_bsd_sendto(_fd, buf.cast(), data.length, 0, addr.cast(), len);
      if (n < 0) {
        if (wouldBlock(zts_errno)) return 0;
        throw ZeroTierException('sendto $toAddress:$toPort', code: n, errno: zts_errno);
      }
      return n;
    } finally {
      calloc.free(buf);
      calloc.free(addr);
    }
  }

  void _receive() {
    final buf = calloc<Uint8>(_readSize);
    final addr = calloc<zts_sockaddr_storage>();
    final len = calloc<Uint32>();
    try {
      while (true) {
        len.value = sizeOf<zts_sockaddr_storage>();
        final n = zts_bsd_recvfrom(_fd, buf.cast(), _readSize, 0, addr.cast(), len);
        if (n < 0) return;
        final (ip, port) = sockaddrToString(addr.cast(), len.value);
        _packets.add(ZeroTierDatagram(copyBytes(buf, n), ip, port));
      }
    } finally {
      calloc.free(buf);
      calloc.free(addr);
      calloc.free(len);
    }
  }

  @override
  StreamSubscription<ZeroTierDatagram> listen(void Function(ZeroTierDatagram)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _packets.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  void close() {
    Poller.instance.unregister(_fd);
    zts_bsd_close(_fd);
    _packets.close();
  }
}
