import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';

/// A libzt call failed.
class ZeroTierException implements Exception {
  ZeroTierException(this.message, {this.code, this.errno});

  final String message;

  /// libzt's return value (`ZTS_ERR_*`).
  final int? code;

  /// `zts_errno` at the time of the failure.
  final int? errno;

  @override
  String toString() => 'ZeroTierException: $message${code == null ? '' : ' (code $code'}${errno == null ? '' : ', errno $errno'}${code == null ? '' : ')'}';
}

/// Throws when [result] is negative.
int check(int result, String what) {
  if (result < 0) throw ZeroTierException(what, code: result, errno: zts_errno);
  return result;
}

bool wouldBlock(int errno) => errno == zts_errno_t.ZTS_EAGAIN.value || errno == zts_errno_t.ZTS_EINPROGRESS.value;

/// Runs [body] with a C string, then frees it.
T withCString<T>(String s, T Function(Pointer<Char> p) body) {
  final p = s.toNativeUtf8().cast<Char>();
  try {
    return body(p);
  } finally {
    malloc.free(p);
  }
}

/// A sockaddr for `ip:port` (IPv4 or IPv6) — free with [malloc.free].
(Pointer<zts_sockaddr_storage>, int) sockaddr(String ip, int port) {
  final storage = calloc<zts_sockaddr_storage>();
  final len = calloc<Uint32>()..value = sizeOf<zts_sockaddr_storage>();
  try {
    final r = withCString(ip, (p) => zts_util_ipstr_to_saddr(p, port, storage.cast(), len));
    if (r < 0) {
      calloc.free(storage);
      throw ZeroTierException('Not an IP address: $ip', code: r);
    }
    return (storage, len.value);
  } finally {
    calloc.free(len);
  }
}

/// `(ip, port)` of a sockaddr.
(String, int) sockaddrToString(Pointer<zts_sockaddr> addr, int len) {
  final buf = calloc<Char>(ZTS_IP_MAX_STR_LEN);
  final port = calloc<UnsignedShort>();
  try {
    zts_util_ntop(addr, len, buf, ZTS_IP_MAX_STR_LEN, port);
    return (buf.cast<Utf8>().toDartString(), port.value);
  } finally {
    calloc.free(buf);
    calloc.free(port);
  }
}

/// Address family for an IP string (`ZTS_AF_INET` or `ZTS_AF_INET6`).
int familyOf(String ip) => ip.contains(':') ? ZTS_AF_INET6 : ZTS_AF_INET;

/// Copies [n] bytes out of native memory.
Uint8List copyBytes(Pointer<Uint8> p, int n) => Uint8List.fromList(p.asTypedList(n));
