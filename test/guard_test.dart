import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final (kind, name) in [(1, 'an overrun'), (2, 'a write after free'), (3, 'a double free')]) {
    test('$name kills the process at once', () async {
      final r = await Process.run(Platform.resolvedExecutable, ['run', 'test/guard_selftest_main.dart', '$kind']);
      expect('${r.stdout}', isNot(contains('survived')), reason: '${r.stderr}');
      // Killed by the fault itself (SIGSEGV at the guard page, SIGILL/SIGTRAP from the double-free trap).
      expect('${r.stdout}${r.stderr}', matches(RegExp(r'si_signo=(Segmentation fault|Illegal instruction|Trace)')));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
