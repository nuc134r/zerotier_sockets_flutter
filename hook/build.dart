// Builds libzt for the target being compiled and bundles it as a code asset (Dart native assets).
//
// The sources come from a local checkout (with submodules) when the app's pubspec.yaml sets
//
//   hooks:
//     user_defines:
//       zerotier_sockets:
//         libzt_src: ../libzt
//
// otherwise the pinned libzt commit is cloned once into the hook's shared cache (offline builds,
// F-Droid: vendor a checkout and use libzt_src). Needs git, CMake and a C/C++ toolchain (the Android
// NDK for Android targets).
//
// `memory_guard: true` (same place) builds libzt with a guarded allocator for finding heap corruption:
// see hook/guard/zt_guard.c. It costs memory and speed; leave it off unless you are hunting a crash.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';

/// libzt 1.8.10.
const libztRepo = 'https://github.com/zerotier/libzt.git';
const libztCommit = 'a6f6886a8c8c07249f9e5d0cae431848727fe845';

/// Fixes applied to the pinned libzt (hook/patches, in name order). Bump [patchLevel] when they change, so
/// cached checkouts are fetched and patched again. A libzt_src checkout is used as it is: apply them there.
///
/// 0001: event structs were filled past their end (a peer with more than 16 paths, a network with more
/// than 16 addresses or 32 routes): heap corruption that crashed apps at random.
const patchLevel = 1;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    hierarchicalLoggingEnabled = true;
    final logger = Logger('libzt')
      ..level = Level.INFO
      ..onRecord.listen((r) => stderr.writeln('${r.level.name}: ${r.message}'));

    final source = await _sources(input, logger);
    final os = input.config.code.targetOS;
    final guard = input.userDefines['memory_guard'] == true;
    final guardCmake = input.packageRoot.resolve('hook/guard/zt_guard.cmake');
    final outDir = input.outputDirectory.resolve('build/');
    // A build directory configured for another source (an older patch level) makes CMake refuse.
    final cache = File.fromUri(outDir.resolve('CMakeCache.txt'));
    if (cache.existsSync()) {
      final home = RegExp(r'^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$', multiLine: true).firstMatch(cache.readAsStringSync());
      final configured = home?.group(1);
      final wanted = Directory.fromUri(source).absolute.path.replaceAll(RegExp(r'/+$'), '');
      if (configured != null && configured != wanted) {
        logger.info('Sources changed ($configured): building afresh');
        Directory.fromUri(outDir).deleteSync(recursive: true);
      }
    }
    final builder = CMakeBuilder.create(
      name: 'zt',
      sourceDir: source,
      outDir: outDir,
      defines: {
        'CMAKE_BUILD_TYPE': 'Release',
        // libzt and its submodules declare cmake_minimum_required < 3.5, which CMake 4 refuses.
        'CMAKE_POLICY_VERSION_MINIMUM': '3.5',
        'BUILD_HOST_SELFTEST': 'OFF',
        'BUILD_STATIC_LIB': 'OFF',
        'ALLOW_INSTALL_TARGET': 'OFF',
        // C API only: no JNI glue on Android.
        'ZTS_NDK_ONLY': 'ON',
        // Strip symbols (kept with the guard, so a crash names the libzt function); 16 KB pages for
        // Android 15+ devices.
        'CMAKE_SHARED_LINKER_FLAGS': [if (!guard) '-s', if (os == OS.android) '-Wl,-z,max-page-size=16384'].join(' '),
        if (guard) 'CMAKE_PROJECT_zt_INCLUDE': guardCmake.toFilePath(),
      },
      targets: ['zt-shared'],
      logger: logger,
    );
    await builder.run(input: input, output: output, logger: logger);

    final lib = _find(Directory.fromUri(outDir), os.dylibFileName('zt'));
    if (lib == null) throw StateError('libzt was built but ${os.dylibFileName('zt')} was not found under $outDir');
    output.assets.code.add(
      CodeAsset(package: input.packageName, name: 'libzt.dart', linkMode: DynamicLoadingBundled(), file: lib.uri),
    );
    output.dependencies.add(source.resolve('CMakeLists.txt'));
    if (guard) {
      output.dependencies
        ..add(guardCmake)
        ..add(input.packageRoot.resolve('hook/guard/zt_guard.c'));
    }
  });
}

Future<Uri> _sources(BuildInput input, Logger logger) async {
  final local = input.userDefines.path('libzt_src');
  if (local != null) return local.path.endsWith('/') ? local : Uri.directory(local.toFilePath());

  final dir = Directory.fromUri(input.outputDirectoryShared.resolve('libzt-$libztCommit-p$patchLevel/'));
  final marker = File.fromUri(dir.uri.resolve('.nux-complete'));
  if (await marker.exists()) return dir.uri;

  logger.info('Fetching libzt $libztCommit');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: dir.path);
    if (r.exitCode != 0) throw ProcessException('git', args, '${r.stderr}', r.exitCode);
  }

  await git(['init', '-q']);
  await git(['remote', 'add', 'origin', libztRepo]);
  await git(['fetch', '-q', '--depth', '1', 'origin', libztCommit]);
  await git(['checkout', '-q', 'FETCH_HEAD']);
  await git(['submodule', 'update', '--init', '--depth', '1', '-q']);
  final patches = Directory.fromUri(input.packageRoot.resolve('hook/patches/'));
  final files = patches.existsSync()
      ? (patches.listSync().whereType<File>().where((f) => f.path.endsWith('.patch')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  for (final patch in files) {
    logger.info('Applying ${patch.uri.pathSegments.last}');
    await git(['apply', patch.path]);
  }
  await marker.writeAsString('$libztCommit p$patchLevel');
  return dir.uri;
}

File? _find(Directory dir, String name) {
  if (!dir.existsSync()) return null;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.uri.pathSegments.last == name) return e;
  }
  return null;
}
