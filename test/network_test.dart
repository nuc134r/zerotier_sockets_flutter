@Tags(['network'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zerotier_sockets/zerotier_sockets.dart';

/// Real traffic over a real network. Opt-in:
///   `ZT_TEST_NETWORK=8056c2e21c000001 ZT_TEST_ECHO=10.147.17.5:7 dart test -t network`
/// where a member of that network runs a TCP and UDP echo server (e.g. `socat`), and this node is
/// authorized (its id is printed on the first run; persist ZT_TEST_STORAGE to keep it).
void main() {
  final net = parseNetworkId(Platform.environment['ZT_TEST_NETWORK'] ?? '');
  final echo = Platform.environment['ZT_TEST_ECHO']?.split(':');
  if (net == null || echo == null || echo.length != 2) {
    test('real network', () {}, skip: 'set ZT_TEST_NETWORK and ZT_TEST_ECHO');
    return;
  }
  final host = echo[0];
  final port = int.parse(echo[1]);
  final node = ZeroTierNode.instance;

  setUpAll(() async {
    node.initStorage(Platform.environment['ZT_TEST_STORAGE'] ?? Directory.systemTemp.createTempSync('zt-net-').path);
    await node.start();
    node.join(net);
    // ignore: avoid_print
    print('node ${await node.watch().map((s) => s.nodeId).firstWhere((id) => id != null)} joining ${net.toRadixString(16)}');
    await node.waitUntilReady(networkId: net, timeout: const Duration(minutes: 2));
  });
  tearDownAll(node.stop);

  test('TCP echo', () async {
    final s = await ZeroTierSocket.connect(host, port);
    addTearDown(s.destroy);
    final reply = s.stream.first;
    s.add(utf8.encode('hello over zerotier\n'));
    expect(utf8.decode(await reply.timeout(const Duration(seconds: 10))), 'hello over zerotier\n');
  });

  test('UDP echo', () async {
    final udp = ZeroTierDatagramSocket.bind('0.0.0.0', 0);
    addTearDown(udp.close);
    final reply = udp.first;
    udp.send(utf8.encode('udp over zerotier'), host, port);
    expect(utf8.decode((await reply.timeout(const Duration(seconds: 10))).data), 'udp over zerotier');
  });
}
