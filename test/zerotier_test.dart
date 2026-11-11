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

  test('the guarded allocator (memory_guard in pubspec.yaml) holds libzt\'s allocations', () {
    final stats = ZeroTierMemoryGuard.stats();
    expect(stats, isNotNull);
    expect(stats!.allocations, greaterThan(0));
    expect(stats.live, greaterThan(0));
    expect(stats.fallbacks, 0, reason: 'nothing went to the unguarded allocator');
  });

  test('network ids', () {
    expect(parseNetworkId('8056c2e21c000001'), BigInt.parse('8056c2e21c000001', radix: 16));
    expect(parseNetworkId('not an id'), isNull);
    final state = node.network(parseNetworkId('8056c2e21c000001')!);
    expect(state.idHex, '8056c2e21c000001');
  });

  test('node and network details, peers', () {
    expect(node.port, isNotNull);
    final unknown = node.details(parseNetworkId('8056c2e21c000001')!);
    expect(unknown.addresses, isEmpty);
    expect(unknown.routes, isEmpty);
    // Offline here: no peers, or the roots once it reaches them.
    expect(node.peers().every((p) => RegExp(r'^[0-9a-f]{10}$').hasMatch(p.address)), isTrue);
    expect(node.neighbors(), isEmpty, reason: 'no network, no traffic');
  });

  test('neighbors text; ZeroTier addresses inside IPv6 addresses', () {
    expect(parseNeighbors('8056c2e21c000001 192.0.2.7 0123456789\njunk\n'), [
      const ZeroTierNeighbor(networkId: '8056c2e21c000001', ip: '192.0.2.7', address: '0123456789'),
    ]);
    // RFC4193: fd + network id + 9993 + address.
    expect(zeroTierAddressFromIp('fd80:56c2:e21c:0000:0199:9301:2345:6789', '8056c2e21c000001'), '0123456789');
    // 6PLANE: fc + (upper 32 bits ^ lower 32 bits of the network id) + address.
    expect(zeroTierAddressFromIp('fc9c:56c2:e301:2345:6789::1', '8056c2e21c000001'), '0123456789');
    expect(zeroTierAddressFromIp('2001:db8::1', '8056c2e21c000001'), isNull);
    expect(zeroTierAddressFromIp('192.0.2.7', '8056c2e21c000001'), isNull);
  });

  test('details and peers text', () {
    final (addresses, routes) = parseNetworkDetails(
      'addr fd00:db8::1/88\naddr 192.0.2.5/24\nroute 192.0.2.0/24 - 0 0\nroute 198.51.100.0/24 192.0.2.1 1 5\n',
    );
    expect(addresses, ['192.0.2.5/24', 'fd00:db8::1/88']);
    expect(routes, [
      const ZeroTierRoute(target: '192.0.2.0/24'),
      const ZeroTierRoute(target: '198.51.100.0/24', via: '192.0.2.1', flags: 1, metric: 5),
    ]);
    final peers = parsePeers('0123456789 2 87 -1.-1.-1 192.0.2.9/9993*\nabcdefabcd 0 -1 1.14.2\n');
    expect(peers, hasLength(2));
    expect(peers[0].role, ZeroTierPeerRole.planet);
    expect(peers[0].latency, 87);
    expect(peers[0].version, isNull);
    expect(peers[0].paths, [const ZeroTierPath('192.0.2.9/9993', preferred: true)]);
    expect(peers[1].direct, isFalse);
    expect(peers[1].latency, isNull);
    expect(peers[1].version, '1.14.2');
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

  test('joining right after start waits for the node (libzt crashed on a null node)', () async {
    await node.stop();
    final starting = node.start();
    // As an app restoring two networks does: join while libzt is still creating its node.
    final a = parseNetworkId('8056c2e21c000001')!, b = parseNetworkId('8056c2e21c000002')!;
    node
      ..join(a)
      ..join(b);
    await starting;
    expect(node.joined, {a, b});
    await Future<void>.delayed(const Duration(milliseconds: 500)); // the process would be gone by now
    expect(node.nodeId, isNotNull);
    expect(node.network(a).idHex, '8056c2e21c000001');
    node
      ..leave(a)
      ..leave(b);
  });
}
