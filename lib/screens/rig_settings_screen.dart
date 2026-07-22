import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;

import '../connection_state.dart';

class RigSettingsScreen extends StatefulWidget {
  final AppConnectionState appState;

  const RigSettingsScreen({super.key, required this.appState});

  @override
  State<RigSettingsScreen> createState() => _RigSettingsScreenState();
}

class _RigSettingsScreenState extends State<RigSettingsScreen> {
  OpenRigHotspotClient? _api;
  bool _loading = true;
  String? _error;
  bool _saving = false;

  // Editable state for the first (or only) rig entry
  bool _enabled = true;
  int _hamlibModelId = 1;
  late TextEditingController _portCtrl;
  int _baud = 9600;
  String _parity = 'none';
  String _handshake = 'none';

  static const _baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];
  static const _parityOptions = ['none', 'even', 'odd'];
  static const _handshakeOptions = ['none', 'hardware', 'software'];

  @override
  void initState() {
    super.initState();
    _portCtrl = TextEditingController(text: '/dev/ttyUSB0');
    _initApi();
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    _api?.dispose();
    super.dispose();
  }

  void _initApi() {
    final device = widget.appState.device;
    if (device == null) {
      setState(() {
        _loading = false;
        _error = 'No device connected';
      });
      return;
    }
    _api = OpenRigHotspotClient(host: device.host);
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _api!.getRigConfig();
      if (mounted) {
        setState(() {
          if (config.rigs.isNotEmpty) {
            final rig = config.rigs.first;
            _enabled = rig.enabled;
            _hamlibModelId = rig.hamlibModelId;
            _portCtrl.text = rig.port;
            _baud = rig.baud;
            _parity = rig.parity;
            _handshake = rig.handshake;
          }
          _loading = false;
          _error = null;
        });
      }
    } on OpenRigApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'API error: ${e.statusCode}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Connection failed: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_api == null) return;
    setState(() => _saving = true);
    final entry = ApiRigEntry(
      enabled: _enabled,
      hamlibModelId: _hamlibModelId,
      port: _portCtrl.text.trim(),
      baud: _baud,
      parity: _parity,
      handshake: _handshake,
    );
    final config = RigConfig(rigs: [entry]);
    try {
      await _api!.updateRigConfig(config);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on OpenRigApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: ${e.statusCode}')),
        );
        setState(() => _saving = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  String _modelName(int id) {
    for (final m in kCommonHamlibModels) {
      if (m.id == id) return '${m.manufacturer} ${m.name}';
    }
    return 'Model $id';
  }

  void _showModelPicker() {
    final searchCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = kCommonHamlibModels.where((m) {
            if (query.isEmpty) return true;
            return m.name.toLowerCase().contains(query) ||
                m.manufacturer.toLowerCase().contains(query) ||
                m.id.toString().contains(query);
          }).toList();

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            builder: (ctx, scrollCtrl) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: searchCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Search models',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (_) => setSheetState(() {}),
                    autofocus: true,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final m = filtered[i];
                      final selected = m.id == _hamlibModelId;
                      return ListTile(
                        title: Text(m.name),
                        subtitle: Text('${m.manufacturer} (ID ${m.id})'),
                        trailing: selected
                            ? const Icon(Icons.check, color: Colors.green)
                            : null,
                        selected: selected,
                        onTap: () {
                          setState(() => _hamlibModelId = m.id);
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rig Settings'),
        actions: [
          FilledButton(
            onPressed: _saving || _loading || _error != null ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _loadConfig();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Enabled switch
                    SwitchListTile(
                      title: const Text('Enabled'),
                      subtitle: const Text('Start rigctld on this device'),
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                    const Divider(),

                    // Hamlib model
                    ListTile(
                      title: const Text('Hamlib Model'),
                      subtitle: Text(_modelName(_hamlibModelId)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _showModelPicker,
                    ),
                    const Divider(),

                    // Serial port
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: TextField(
                        controller: _portCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Serial Port',
                          hintText: '/dev/ttyUSB0',
                        ),
                      ),
                    ),
                    const Divider(),

                    // Baud rate
                    ListTile(
                      title: const Text('Baud Rate'),
                      trailing: DropdownButton<int>(
                        value: _baudRates.contains(_baud) ? _baud : 9600,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final b in _baudRates)
                            DropdownMenuItem(value: b, child: Text(b.toString())),
                        ],
                        onChanged: (v) => setState(() => _baud = v ?? 9600),
                      ),
                    ),
                    const Divider(),

                    // Parity
                    ListTile(
                      title: const Text('Parity'),
                      trailing: DropdownButton<String>(
                        value: _parityOptions.contains(_parity) ? _parity : 'none',
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final p in _parityOptions)
                            DropdownMenuItem(
                              value: p,
                              child: Text(p[0].toUpperCase() + p.substring(1)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _parity = v ?? 'none'),
                      ),
                    ),
                    const Divider(),

                    // Handshake
                    ListTile(
                      title: const Text('Handshake'),
                      trailing: DropdownButton<String>(
                        value: _handshakeOptions.contains(_handshake) ? _handshake : 'none',
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final h in _handshakeOptions)
                            DropdownMenuItem(
                              value: h,
                              child: Text(h[0].toUpperCase() + h.substring(1)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _handshake = v ?? 'none'),
                      ),
                    ),

                    const SizedBox(height: 24),
                    Text(
                      'Changes take effect after saving and restarting rigctld.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
    );
  }
}
