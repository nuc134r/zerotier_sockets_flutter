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
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';

/// libzt 1.8.10.
const libztRepo = 'https://github.com/zerotier/libzt.git';
const libztCommit = 'a6f6886a8c8c07249f9e5d0cae431848727fe845';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    hierarchicalLoggingEnabled = true;
    final logger = Logger('libzt')
      ..level = Level.INFO
      ..onRecord.listen((r) => stderr.writeln('${r.level.name}: ${r.message}'));

    final source = await _sources(input, logger);
    final os = input.config.code.targetOS;
    final outDir = input.outputDirectory.resolve('build/');
    final builder = CMakeBuilder.create(
      name: 'zt',
      sourceDir: source,
      outDir: outDir,
      defines: {
        'CMAKE_BUILD_TYPE': 'Release',
        'BUILD_HOST_SELFTEST': 'OFF',
        'BUILD_STATIC_LIB': 'OFF',
        'ALLOW_INSTALL_TARGET': 'OFF',
        // C API only: no JNI glue on Android.
        'ZTS_NDK_ONLY': 'ON',
        // Strip symbols; 16 KB pages for Android 15+ devices.
        'CMAKE_SHARED_LINKER_FLAGS': os == OS.android ? '-s -Wl,-z,max-page-size=16384' : '-s',
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
  });
}

Future<Uri> _sources(BuildInput input, Logger logger) async {
  final local = input.userDefines.path('libzt_src');
  if (local != null) return local.path.endsWith('/') ? local : Uri.directory(local.toFilePath());

  final dir = Directory.fromUri(input.outputDirectoryShared.resolve('libzt-$libztCommit/'));
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
  await marker.writeAsString(libztCommit);
  return dir.uri;
}

File? _find(Directory dir, String name) {
  if (!dir.existsSync()) return null;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.uri.pathSegments.last == name) return e;
  }
  return null;
}
