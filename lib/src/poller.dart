import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';

typedef PollHandler = void Function(int revents);

/// One loop that polls every open libzt socket (non-blocking `zts_bsd_poll`) and calls their handlers.
/// It only runs while sockets are registered, faster while traffic flows.
class Poller {
  Poller._();

  static final instance = Poller._();

  final Map<int, (int events, PollHandler handler)> _fds = {};
  Timer? _timer;
  int _quietTicks = 0;

  void register(int fd, int events, PollHandler handler) {
    _fds[fd] = (events, handler);
    _schedule(Duration.zero);
  }

  /// Changes what [fd] waits for (e.g. add POLLOUT while a write is pending).
  void setEvents(int fd, int events) {
    final entry = _fds[fd];
    if (entry != null) _fds[fd] = (events, entry.$2);
    _schedule(Duration.zero);
  }

  void unregister(int fd) => _fds.remove(fd);

  void _schedule(Duration delay) {
    if (_timer?.isActive ?? false) return;
    _timer = Timer(delay, _tick);
  }

  void _tick() {
    if (_fds.isEmpty) return;
    final n = _fds.length;
    final fds = calloc<zts_pollfd>(n);
    final order = _fds.keys.toList();
    try {
      for (var i = 0; i < n; i++) {
        fds[i]
          ..fd = order[i]
          ..events = _fds[order[i]]!.$1
          ..revents = 0;
      }
      final ready = zts_bsd_poll(fds, n, 0);
      if (ready > 0) {
        _quietTicks = 0;
        for (var i = 0; i < n; i++) {
          final revents = fds[i].revents;
          if (revents != 0) _fds[order[i]]?.$2(revents);
        }
      } else {
        _quietTicks++;
      }
    } finally {
      calloc.free(fds);
    }
    // 2 ms while busy, backing off to 50 ms when idle.
    _schedule(Duration(milliseconds: _quietTicks < 10 ? 2 : (_quietTicks < 100 ? 10 : 50)));
  }
}
