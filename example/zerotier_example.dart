import 'dart:convert';
import 'dart:io';

import 'package:zerotier_sockets/zerotier_sockets.dart';

/// `dart run example/zerotier_example.dart 8056c2e21c000001 10.147.17.5 22`
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: zerotier_example <network id> <ip> <port>');
    exit(64);
  }
  final net = parseNetworkId(args[0])!;
  final node = ZeroTierNode.instance
    ..initStorage('${Directory.systemTemp.path}/zerotier_example')
    ..start()
    ..join(net);
  node.watch().listen((s) => print('online: ${s.online}, networks: ${s.networks.map((n) => '${n.idHex} ${n.status.name} ${n.addresses}')}'));
  await node.waitUntilReady(networkId: net, timeout: const Duration(minutes: 2));
  final socket = await ZeroTierSocket.connect(args[1], int.parse(args[2]));
  socket.stream.map(utf8.decode).listen(stdout.write, onDone: () => exit(0));
  stdin.listen(socket.add);
}
