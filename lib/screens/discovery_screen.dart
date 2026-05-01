import 'dart:async';
import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';

import '../connection_state.dart';

class DiscoveryScreen extends StatefulWidget {
  final AppConnectionState appState;

  const DiscoveryScreen({super.key, required this.appState});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  OpenRigDiscovery? _discovery;
  final _devices = <String, OpenRigDevice>{};
  StreamSubscription<OpenRigDevice>? _foundSub;
  StreamSubscription<String>? _lostSub;
  bool _searching = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    _discovery = OpenRigDiscovery();
    _foundSub = _discovery!.onDeviceFound.listen((device) {
      setState(() {
        _devices[device.host] = device;
        _searching = false;
      });
    });
    _lostSub = _discovery!.onDeviceLost.listen((host) {
      setState(() => _devices.remove(host));
    });
    try {
      await _discovery!.start();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _searching = false;
      });
    }
  }

  @override
  void dispose() {
    _foundSub?.cancel();
    _lostSub?.cancel();
    _discovery?.stop();
    super.dispose();
  }

  void _selectDevice(OpenRigDevice device) {
    widget.appState.setDevice(device);
    Navigator.of(context).pushReplacementNamed('/home');
  }

  void _showManualEntry() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manual Connection'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'IP address or hostname',
            hintText: '192.168.1.100',
          ),
          autofocus: true,
          onSubmitted: (_) => _submitManual(controller.text, ctx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => _submitManual(controller.text, ctx),
            child: const Text('CONNECT'),
          ),
        ],
      ),
    );
  }

  void _submitManual(String host, BuildContext ctx) {
    final trimmed = host.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(ctx).pop();
    widget.appState.setManualDevice(trimmed);
    Navigator.of(context).pushReplacementNamed('/home');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final deviceList = _devices.values.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('openRig Mobile')),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Discovery error: $_error',
                  style: TextStyle(color: colorScheme.error)),
            ),

          if (_searching && deviceList.isEmpty)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Searching for openRig devices...'),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: deviceList.isEmpty
                  ? const Center(child: Text('No devices found'))
                  : ListView.builder(
                      itemCount: deviceList.length,
                      itemBuilder: (context, index) {
                        final d = deviceList[index];
                        return ListTile(
                          leading: Icon(
                            d.hasRigctld ? Icons.settings_remote : Icons.router,
                            color: colorScheme.primary,
                          ),
                          title: Text(
                            d.callsign.isNotEmpty ? d.callsign : d.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text('${d.host}  •  ${d.type}'),
                          trailing: d.hasRigctld
                              ? Chip(
                                  label: const Text('rigctld'),
                                  backgroundColor: colorScheme.primaryContainer,
                                )
                              : null,
                          onTap: () => _selectDevice(d),
                        );
                      },
                    ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showManualEntry,
        icon: const Icon(Icons.edit),
        label: const Text('Manual'),
      ),
    );
  }
}
