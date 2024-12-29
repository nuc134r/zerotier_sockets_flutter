import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zerotier_sockets/zerotier_sockets.dart';

import 'dialogs.dart';
import 'network_model.dart';
import 'socket_model.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: "ZeroTier Sockets",
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  HomePageState() {
    _node = ZeroTierNode.instance;
  }

  late final ZeroTierNode _node;
  late final Timer _timer;

  bool _startNode = false;
  bool _allowStartNode = true;
  bool _running = false;
  bool _online = false;
  String _identity = 'none';

  final List<BigInt> _networkIds = [];
  final List<NetworkModel> _networks = [];
  final List<SocketModel> _sockets = [];

  Future<void> _toggleStartNode(bool value) async {
    setState(() => _allowStartNode = false);

    _startNode = value;
    if (value) {
      _node.start();
    } else {
      _networkIds.clear();
      _networks.clear();
      _node.stop();
    }

    // a little cooldown to prevent spamming which leads to crash
    await Future.delayed(const Duration(milliseconds: 500));
    setState(() => _allowStartNode = true);
  }

  Future<void> _onJoinNetwork() async {
    var result = await InputDialog.show(
        context, title: 'Join network', hint: 'Network ID', sendText: 'ADD');
    if (result != null) {
      var networkId = BigInt.tryParse(result, radix: 16);
      if (networkId != null && networkId > BigInt.zero) {
        _networkIds.add(networkId);
        _node.join(networkId);
      } else {
        print('Invalid Network ID entered: $result');
      }
    }
  }

  Future<void> _onLeaveNetwork(BigInt networkId) async {
    var result = await BoolDialog.show(context, title: 'Leave network?');
    if (result == true) {
      _networkIds.remove(networkId);
      _node.leave(networkId);
    }
  }

  Future<void> _onCreateSocket() async {
    var address = await InputDialog.show(
        context, title: 'Connect socket', hint: 'IP address', sendText: 'NEXT');
    if (address == null) {
      return;
    }

    var port = await InputDialog.show(
        context, title: 'Connect socket', hint: 'Port', sendText: 'CONNECT');
    if (port == null || int.tryParse(port) == null) {
      return;
    }

    _sockets.add(SocketModel(address, int.parse(port)));
    setState(() {});
  }

  Future<void> _onSocketPress(SocketModel socket) async {
    await ActionDialog.show(
      context,
      title: 'Socket',
      actions: [
        ActionDialogAction(text: 'Reconnect', onPressed: socket.reconnect),
        ActionDialogAction(text: 'Disconnect', onPressed: socket.disconnect),
        ActionDialogAction(
          text: 'Delete',
          onPressed: () {
            _sockets.remove(socket);
            setState(() {});
          },
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _timer =
        Timer.periodic(const Duration(milliseconds: 500), (t) => _updateStatus());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _updateStatus() {
    bool needUpdate = false;

    if (_running != _node.running) {
      _running = _node.running;
      needUpdate = true;
    }

    if (_online != _node.online) {
      _online = _node.online;
      needUpdate = true;
    }

    final id = _node.getId();
    if (id.success) {
      var identity = id.data.toRadixString(16);
      if (identity != _identity) {
        _identity = identity;
        needUpdate = true;
      }
    } else {
      if (_identity != 'none') {
        _identity = 'none';
        needUpdate = true;
      }
    }

    NetworkModel createNetworkModel(BigInt id) {
      var info = _node.getNetworkInfo(id);
      if (info != null) {
        try {
          return NetworkModel.fromInfo(info);
        } catch (e) {
          print('Error creating network model: $e');
        }
      }
      return NetworkModel.fromId(id); // Fallback if info is null or invalid
    }

    if (_networks.length != _networkIds.length) {
      needUpdate = true;
      _networks.clear();
      for (BigInt id in _networkIds) {
        _networks.add(createNetworkModel(id));
      }
    } else {
      for (var i = 0; i < _networkIds.length; i++) {
        var model = createNetworkModel(_networkIds[i]);
        if (!model.equals(_networks[i])) {
          _networks[i] = model;
          needUpdate = true;
        }
      }
    }

    if (needUpdate) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('ZeroTier Sockets'),
        ),
        body: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Start node'),
                      value: _startNode,
                      enableFeedback: true,
                      onChanged: _allowStartNode ? _toggleStartNode : null,
                    ),
                    ListTile(
                      title: const Text('Status'),
                      trailing: Text(
                        _running ? (_online ? 'online' : 'connecting...') : 'not running',
                      ),
                    ),
                    ListTile(
                      title: const Text('Identity'),
                      trailing: Text(_identity),
                    ),
                    ...(!_running)
                        ? []
                        : [
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text('Networks', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.start),
                            ),
                            ..._networks.map((model) {
                              return ListTile(
                                leading: const Icon(Icons.public),
                                minLeadingWidth: 20,
                                title: Text(model.name),
                                subtitle: Text('${model.id.toRadixString(16)}\r\n${model.address} • ${model.type}'),
                                trailing: Text(model.status),
                                onTap: () => _onLeaveNetwork(model.id),
                              );
                            }).toList(),
                            ListTile(
                              leading: const Icon(Icons.add),
                              minLeadingWidth: 20,
                              title: const Text('Join network'),
                              onTap: _onJoinNetwork,
                            ),
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text('Socket instances', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.start),
                            ),
                            ..._sockets.map(
                              (e) => AnimatedBuilder(
                                animation: e,
                                builder: (context, child) => ListTile(
                                  leading: const Icon(Icons.public),
                                  minLeadingWidth: 20,
                                  title: Text('${e.address}:${e.port}'),
                                  subtitle: Text(e.status),
                                  onTap: () => _onSocketPress(e),
                                ),
                              ),
                            ),
                            ListTile(
                              leading: const Icon(Icons.add),
                              minLeadingWidth: 20,
                              title: const Text('Create socket'),
                              onTap: _onCreateSocket,
                            ),
                          ],
                  ],
                ),
              ),
            ),
          )
        ]),
      ),
    );
  }
}
