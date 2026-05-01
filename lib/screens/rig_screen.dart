import 'dart:async';
import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;

import '../connection_state.dart';
import 'rig_settings_screen.dart';

class RigScreen extends StatefulWidget {
  final AppConnectionState appState;

  const RigScreen({super.key, required this.appState});

  @override
  State<RigScreen> createState() => _RigScreenState();
}

class _RigScreenState extends State<RigScreen> {
  Timer? _pollTimer;
  int _frequencyHz = 0;
  String _mode = '';
  bool _pttActive = false;
  String? _error;

  static const _modes = ['USB', 'LSB', 'CW', 'FM', 'AM'];

  RigManager get _rigManager => widget.appState.rigManager;
  RigEntry? get _activeRig => _rigManager.activeRig;
  RigClient? get _client => _activeRig?.client;
  bool get _connected => _activeRig?.connected ?? false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onStateChanged);
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    widget.appState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) {
      setState(() {});
      _restartPolling();
    }
  }

  void _restartPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_connected) {
      _startPolling();
    }
  }

  void _startPolling() {
    if (!_connected) return;
    _poll();
    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final client = _client;
    if (client == null || !client.isConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    try {
      final freq = await client.getFrequency();
      final modeResult = await client.getMode();
      if (mounted) {
        setState(() {
          _frequencyHz = freq;
          _mode = modeResult.mode;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _setMode(String mode) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.setMode(mode);
      setState(() => _mode = mode);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _setPtt(bool on) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.setPtt(on);
      setState(() => _pttActive = on);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _showAddRigDialog() {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '4532');
    final labelCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Rig'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(labelText: 'Host / IP'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portCtrl,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () async {
              final host = hostCtrl.text.trim();
              if (host.isEmpty) return;
              final port = int.tryParse(portCtrl.text.trim()) ?? 4532;
              final label = labelCtrl.text.trim();
              Navigator.of(ctx).pop();
              try {
                await _rigManager.addRig(
                  host: host,
                  port: port,
                  label: label.isNotEmpty ? label : null,
                );
              } on StateError catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.message)),
                  );
                }
              }
            },
            child: const Text('ADD'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rigs = _rigManager.rigs;
    final activeId = _activeRig?.id;
    final selectedModes = _modes.contains(_mode) ? {_mode} : <String>{};

    return Column(
      children: [
        // Rig selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Expanded(
                child: rigs.isEmpty
                    ? Text(
                        'No rigs added',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final rig in rigs)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(rig.label),
                                  selected: rig.id == activeId,
                                  avatar: Icon(
                                    rig.connected
                                        ? Icons.link
                                        : Icons.link_off,
                                    size: 16,
                                    color: rig.connected
                                        ? Colors.green
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  onSelected: (_) =>
                                      _rigManager.setActiveRig(rig.id),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add rig',
                onPressed: _showAddRigDialog,
                visualDensity: VisualDensity.compact,
              ),
              if (widget.appState.device != null)
                IconButton(
                  icon: const Icon(Icons.settings, size: 20),
                  tooltip: 'Rig settings',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RigSettingsScreen(
                          appState: widget.appState,
                        ),
                      ),
                    );
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),

        if (!_connected)
          MaterialBanner(
            content: Text(_error ?? 'Not connected — no rig linked'),
            leading: Icon(Icons.link_off, color: colorScheme.error),
            backgroundColor: colorScheme.errorContainer.withAlpha(80),
            actions: [
              if (_activeRig != null)
                TextButton(
                  onPressed: () async {
                    try {
                      await _rigManager.connectRig(_activeRig!.id);
                    } catch (_) {}
                  },
                  child: const Text('CONNECT'),
                )
              else
                TextButton(
                  onPressed: _showAddRigDialog,
                  child: const Text('ADD RIG'),
                ),
            ],
          ),

        const Spacer(),

        Text(
          _connected ? formatFrequency(_frequencyHz) : '-.---.---',
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: colorScheme.primary,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 4),
        Text('MHz', style: TextStyle(color: colorScheme.onSurfaceVariant)),

        const SizedBox(height: 32),

        SegmentedButton<String>(
          segments: [
            for (final m in _modes) ButtonSegment(value: m, label: Text(m)),
          ],
          selected: selectedModes,
          emptySelectionAllowed: true,
          onSelectionChanged: _connected
              ? (selected) {
                  if (selected.isNotEmpty) _setMode(selected.first);
                }
              : null,
        ),

        const SizedBox(height: 40),

        GestureDetector(
          onTapDown: _connected ? (_) => _setPtt(true) : null,
          onTapUp: _connected ? (_) => _setPtt(false) : null,
          onTapCancel: _connected ? () => _setPtt(false) : null,
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pttActive ? Colors.red : colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: _pttActive ? Colors.red.shade300 : colorScheme.outline,
                width: 3,
              ),
            ),
            child: Center(
              child: Text(
                'PTT',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _pttActive ? Colors.white : colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),

        const Spacer(),
      ],
    );
  }
}
