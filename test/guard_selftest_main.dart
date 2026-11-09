import 'package:zerotier_sockets/zerotier_sockets.dart';

/// Run by guard_test.dart: misuses a guarded allocation the way args[0] says; should never print.
void main(List<String> args) {
  ZeroTierMemoryGuard.selftest(int.parse(args.first));
  print('survived');
}
