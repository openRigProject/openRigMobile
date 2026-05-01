import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' show QrzLogbookClient, QrzException, isValidGrid;
import 'package:path_provider/path_provider.dart';

import '../connection_state.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final AppConnectionState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsService? _settings;
  String _logPath = '';

  @override
  void initState() {
    super.initState();
    _settings = widget.appState.settings;
    _resolveLogPath();
  }

  Future<void> _resolveLogPath() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (mounted) setState(() => _logPath = '${dir.path}/openrig_log.adi');
    } catch (_) {
      if (mounted) setState(() => _logPath = '(unavailable)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final s = _settings;
    final deviceHost = s?.deviceHost;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // -- Operator --
          _SectionHeader(title: 'Operator'),
          _TextFieldTile(
            label: 'Callsign',
            value: s?.callsign ?? '',
            textCapitalization: TextCapitalization.characters,
            onChanged: (v) => s?.setCallsign(v.trim().toUpperCase()),
          ),
          _GridSquareTile(
            value: s?.gridSquare ?? '',
            onChanged: (v) => s?.setGridSquare(v.trim().toUpperCase()),
          ),

          const Divider(),

          // -- DX Cluster --
          _SectionHeader(title: 'DX Cluster'),
          _TextFieldTile(
            label: 'Host',
            value: s?.clusterHost ?? 'dxc.ve7cc.net',
            onChanged: (v) {
              final host = v.trim();
              if (host.isNotEmpty) s?.setCluster(host, s.clusterPort);
            },
          ),
          _TextFieldTile(
            label: 'Port',
            value: (s?.clusterPort ?? 23).toString(),
            keyboardType: TextInputType.number,
            onChanged: (v) {
              final port = int.tryParse(v.trim());
              if (port != null && port > 0) s?.setCluster(s.clusterHost, port);
            },
          ),

          const Divider(),

          // -- Logging --
          _SectionHeader(title: 'Logging'),
          _QrzApiKeyTile(
            value: s?.qrzApiKey ?? '',
            onChanged: (v) => s?.setQrzApiKey(v.trim()),
          ),

          const Divider(),

          // -- Log --
          _SectionHeader(title: 'Log'),
          ListTile(
            title: const Text('Log file path'),
            subtitle: Text(
              _logPath.isEmpty ? 'Resolving...' : _logPath,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: const Icon(Icons.info_outline, size: 18),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'QSO log is stored in the app documents directory in ADIF format.',
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
          ),

          const Divider(),

          // -- Connection --
          _SectionHeader(title: 'Connection'),
          ListTile(
            title: const Text('Last connected device'),
            subtitle: Text(
              deviceHost != null && deviceHost.isNotEmpty
                  ? '$deviceHost:${s?.devicePort ?? 4532}'
                  : 'None',
              style: TextStyle(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (deviceHost != null && deviceHost.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _forgetDevice(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Forget Device'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _forgetDevice(BuildContext context) async {
    await _settings?.clearDevice();
    await widget.appState.disconnectRig();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device forgotten. Discovery will show on next launch.')),
      );
      setState(() {});
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _TextFieldTile extends StatefulWidget {
  final String label;
  final String value;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;

  const _TextFieldTile({
    required this.label,
    required this.value,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
  });

  @override
  State<_TextFieldTile> createState() => _TextFieldTileState();
}

class _TextFieldTileState extends State<_TextFieldTile> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(labelText: widget.label),
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        onChanged: widget.onChanged,
        onSubmitted: widget.onChanged,
      ),
    );
  }
}

class _GridSquareTile extends StatefulWidget {
  final String value;
  final ValueChanged<String>? onChanged;

  const _GridSquareTile({required this.value, this.onChanged});

  @override
  State<_GridSquareTile> createState() => _GridSquareTileState();
}

class _GridSquareTileState extends State<_GridSquareTile> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    final trimmed = v.trim();
    setState(() {
      _errorText = trimmed.isNotEmpty && !isValidGrid(trimmed)
          ? 'Invalid grid square'
          : null;
    });
    if (_errorText == null) {
      widget.onChanged?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: 'Grid Square',
          hintText: 'e.g. FN31',
          errorText: _errorText,
        ),
        textCapitalization: TextCapitalization.characters,
        onChanged: _onChanged,
        onSubmitted: _onChanged,
      ),
    );
  }
}

class _QrzApiKeyTile extends StatefulWidget {
  final String value;
  final ValueChanged<String>? onChanged;

  const _QrzApiKeyTile({required this.value, this.onChanged});

  @override
  State<_QrzApiKeyTile> createState() => _QrzApiKeyTileState();
}

class _QrzApiKeyTileState extends State<_QrzApiKeyTile> {
  late final TextEditingController _controller;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() => _verifying = true);
    final client = QrzLogbookClient(apiKey: key);
    try {
      final callsign = await client.checkKey();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ key valid — $callsign')),
        );
      }
    } on QrzException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ key invalid: ${e.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ verify failed: $e')),
        );
      }
    } finally {
      client.dispose();
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: 'QRZ API Key'),
              obscureText: true,
              onChanged: widget.onChanged,
              onSubmitted: widget.onChanged,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _verifying ? null : _verify,
            child: _verifying
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify'),
          ),
        ],
      ),
    );
  }
}
