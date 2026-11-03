import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zerotier_sockets/zerotier_sockets.dart';

void main() {
  final node = ZeroTierNode.instance;
  late Directory storage;

  setUpAll(() async {
    storage = Directory.systemTemp.createTempSync('zt-node-');
    node.initStorage(storage.path);
    await node.start();
    // The identity is generated (or loaded) right after start, network or not.
    await node.watch(interval: const Duration(milliseconds: 100)).firstWhere((s) => s.nodeId != null).timeout(const Duration(seconds: 30));
  });
  tearDownAll(() async {
    await node.stop();
    storage.deleteSync(recursive: true);
  });

  test('the node has an identity, kept in storage', () {
    expect(node.nodeId, matches(RegExp(r'^[0-9a-f]{10}$')));
    expect(storage.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), contains('identity.secret'));
  });

  test('network ids', () {
    expect(parseNetworkId('8056c2e21c000001'), BigInt.parse('8056c2e21c000001', radix: 16));
    expect(parseNetworkId('not an id'), isNull);
    final state = node.network(parseNetworkId('8056c2e21c000001')!);
    expect(state.idHex, '8056c2e21c000001');
  });

  // Without a joined network lwIP has no interface, not even loopback: sockets bind, sending fails.
  test('sockets bind offline; sending reports the unreachable network', () {
    final udp = ZeroTierDatagramSocket.bind('0.0.0.0', 41001);
    addTearDown(udp.close);
    expect(() => udp.send(utf8.encode('ping'), '10.147.17.1', 41002), throwsA(isA<ZeroTierException>()));
    final server = ZeroTierServerSocket.bind('0.0.0.0', 41010);
    server.close();
  });

  test('connecting without a route fails', () async {
    await expectLater(
      ZeroTierSocket.connect('10.147.17.1', 41099, timeout: const Duration(seconds: 3)),
      throwsA(isA<ZeroTierException>()),
    );
  });

  test('cancelling a watch returns at once, even when nothing changed', () async {
    final sub = node.watch().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel().timeout(const Duration(seconds: 1));
  });

  // Keep last: it restarts the node.
  test('stop and start again, also in quick succession, keeping the identity', () async {
    final id = node.nodeId;
    final stopped = node.stop();
    expect(node.running, isFalse);
    expect(node.nodeId, isNull);
    await node.start(); // waits for the stop
    await stopped;
    unawaited(node.stop());
    await node.start();
    final again = await node.watch(interval: const Duration(milliseconds: 100)).map((s) => s.nodeId).firstWhere((id) => id != null).timeout(const Duration(seconds: 30));
    expect(again, id);
  });
}
