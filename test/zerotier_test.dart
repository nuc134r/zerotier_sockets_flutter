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
    node.start();
    // The identity is generated (or loaded) right after start, network or not.
    await node.watch(interval: const Duration(milliseconds: 100)).firstWhere((s) => s.nodeId != null).timeout(const Duration(seconds: 30));
  });
  tearDownAll(() {
    node.stop();
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
}

