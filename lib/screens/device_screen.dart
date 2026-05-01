import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;

import '../connection_state.dart';

class DeviceScreen extends StatefulWidget {
  final AppConnectionState appState;

  const DeviceScreen({super.key, required this.appState});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  HotspotMonitor? _monitor;
  Future<NetworkStatus?>? _networkFuture;
  Future<List<WifiNetwork>?>? _wifiFuture;

  @override
  void initState() {
    super.initState();
    _initMonitor();
  }

  @override
  void didUpdateWidget(DeviceScreen old) {
    super.didUpdateWidget(old);
    if (widget.appState.device?.host != old.appState.device?.host) {
      _disposeMonitor();
      _initMonitor();
    }
  }

  @override
  void dispose() {
    _disposeMonitor();
    super.dispose();
  }

  void _disposeMonitor() {
    _monitor?.dispose();
    _monitor = null;
    _networkFuture = null;
    _wifiFuture = null;
  }

  void _initMonitor() {
    final device = widget.appState.device;
    if (device == null) return;
    _monitor = HotspotMonitor(host: device.host);
    _monitor!.start();
    _networkFuture = _fetchNetwork(device.host);
    _wifiFuture = _fetchWifi(device.host);
  }

  Future<List<WifiNetwork>?> _fetchWifi(String host) async {
    try {
      final api = OpenRigApiClient(host: host, port: 7373);
      final result = await api.getWifi();
      api.dispose();
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<NetworkStatus?> _fetchNetwork(String host) async {
    try {
      final api = OpenRigApiClient(host: host, port: 7373);
      final result = await api.getNetworkStatus();
      api.dispose();
      return result;
    } catch (_) {
      return null;
    }
  }

  String _formatUptime(int seconds) {
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (d > 0) return '${d}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Future<void> _restartServices(HotspotConfig? hotspot, DeviceStatus? status) async {
    final device = widget.appState.device;
    if (device == null) return;
    final api = OpenRigApiClient(host: device.host, port: 7373);
    final type = status?.type ?? device.type;
    final services = <String>[];
    if (type == 'hotspot') {
      if (hotspot?.dmr.enabled == true) services.add('dmr');
      if (hotspot?.ysf.enabled == true) services.add('ysf');
      if (hotspot?.ysf2dmr.enabled == true) services.add('ysf2dmr');
      if (hotspot?.dmr2ysf.enabled == true) services.add('dmr2ysf');
    }
    if (services.isEmpty) services.add('wifi');

    try {
      for (final s in services) {
        await api.restartService(s);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Services restarted')),
        );
      }
    } on OpenRigApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restart failed: ${e.statusCode}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restart failed: $e')),
        );
      }
    } finally {
      api.dispose();
    }
  }

  Future<void> _reboot() async {
    final device = widget.appState.device;
    if (device == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reboot Device?'),
        content: Text('${device.name} will be unreachable for a moment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = OpenRigApiClient(host: device.host, port: 7373);
    try {
      await api.reboot();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rebooting\u2026')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reboot failed: $e')),
        );
      }
    } finally {
      api.dispose();
    }
  }

  Future<void> _shutdown() async {
    final device = widget.appState.device;
    if (device == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shut Down Device?'),
        content: Text(
          '${device.name} will power off. '
          'You will need physical access to turn it back on.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Shut Down'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = OpenRigApiClient(host: device.host, port: 7373);
    try {
      await api.shutdown();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Shutting down\u2026')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Shutdown failed: $e')),
        );
      }
    } finally {
      api.dispose();
    }
  }

  void _showManageHotspot(HotspotConfig config) {
    final device = widget.appState.device;
    if (device == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _HotspotManageSheet(
        config: config,
        deviceHost: device.host,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.appState.device;

    if (device == null || _monitor == null) {
      return const Center(child: Text('No device selected'));
    }

    return StreamBuilder<DeviceStatus>(
      stream: _monitor!.status,
      builder: (context, statusSnap) {
        final status = statusSnap.data;
        final type = status?.type ?? device.type;
        final isHotspot = type == 'hotspot';
        final isRigctl = type == 'rigctl' || type == 'console';

        // Show loading only if we have no data at all yet
        if (statusSnap.connectionState == ConnectionState.waiting &&
            !statusSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(
              appState: widget.appState,
              status: status,
              formatUptime: _formatUptime,
            ),
            const SizedBox(height: 12),
            FutureBuilder<NetworkStatus?>(
              future: _networkFuture,
              builder: (context, snap) {
                final net = snap.data;
                if (net == null) return const SizedBox.shrink();
                return Column(
                  children: [
                    _NetworkCard(network: net),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
            FutureBuilder<List<WifiNetwork>?>(
              future: _wifiFuture,
              builder: (context, snap) {
                final networks = snap.data;
                if (networks == null) return const SizedBox.shrink();
                return Column(
                  children: [
                    _WifiCard(
                      networks: networks,
                      deviceHost: widget.appState.device!.host,
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
            if (isHotspot) ...[
              StreamBuilder<HotspotConfig>(
                stream: _monitor!.hotspot,
                builder: (context, hotspotSnap) {
                  return StreamBuilder<List<HotspotClient>>(
                    stream: _monitor!.clients,
                    builder: (context, clientsSnap) {
                      final hotspot = hotspotSnap.data;
                      final clients = clientsSnap.data ?? [];
                      if (hotspot == null) {
                        return const Card(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        );
                      }
                      return _HotspotCard(
                        config: hotspot,
                        clientCount: clients.length,
                        onManage: () => _showManageHotspot(hotspot),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
            if (isRigctl) ...[
              const _RigCard(),
              const SizedBox(height: 12),
            ],
            StreamBuilder<HotspotConfig>(
              stream: _monitor!.hotspot,
              builder: (context, hotspotSnap) {
                return _QuickActionsCard(
                  onRestart: () =>
                      _restartServices(hotspotSnap.data, status),
                  onReboot: _reboot,
                  onShutdown: _shutdown,
                );
              },
            ),
          ],
        );
      },
    );
  }
}

// -- Status card --

class _StatusCard extends StatelessWidget {
  final AppConnectionState appState;
  final DeviceStatus? status;
  final String Function(int) formatUptime;
  const _StatusCard({required this.appState, this.status, required this.formatUptime});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final device = appState.device;
    final connected = appState.rigConnected;

    final hostname = status?.hostname ?? device?.name ?? '--';
    final callsign = status?.callsign ?? device?.callsign ?? '--';
    final type = status?.type ?? device?.type ?? 'unknown';
    final ip = device?.host ?? '--';
    final version = status?.version ?? device?.version ?? '--';
    final uptime = status != null ? formatUptime(status!.uptime) : '--';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: connected ? Colors.green : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  hostname,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _TypeBadge(type: type),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Callsign', value: callsign),
            _InfoRow(label: 'IP Address', value: ip),
            _InfoRow(label: 'Version', value: version),
            _InfoRow(label: 'Uptime', value: uptime),
            if (status != null &&
                (status!.cpuPercent > 0 || status!.memTotalMb > 0 || status!.diskTotalGb > 0)) ...[
              const Divider(height: 16),
              _buildMetricRow(context, 'CPU',
                  status!.cpuPercent / 100,
                  '${status!.cpuPercent.toStringAsFixed(1)}%'),
              if (status!.memTotalMb > 0)
                _buildMetricRow(context, 'Memory',
                    status!.memUsedMb / status!.memTotalMb,
                    '${status!.memUsedMb}/${status!.memTotalMb} MB'),
              if (status!.diskTotalGb > 0)
                _InfoRow(
                  label: 'Disk',
                  value: '${status!.diskUsedGb.toStringAsFixed(1)}/'
                      '${status!.diskTotalGb.toStringAsFixed(1)} GB',
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(BuildContext context, String label, double value, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value.clamp(0.0, 1.0)),
                const SizedBox(height: 2),
                Text(text,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Color bg;
    IconData icon;
    switch (type) {
      case 'hotspot':
        bg = Colors.orange.withAlpha(50);
        icon = Icons.cell_tower;
      case 'rigctl':
        bg = Colors.blue.withAlpha(50);
        icon = Icons.settings_remote;
      case 'console':
        bg = Colors.purple.withAlpha(50);
        icon = Icons.computer;
      default:
        bg = colorScheme.surfaceContainerHighest;
        icon = Icons.device_unknown;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(type, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// -- Hotspot card --

class _HotspotCard extends StatelessWidget {
  final HotspotConfig config;
  final int clientCount;
  final VoidCallback onManage;
  const _HotspotCard({required this.config, required this.clientCount, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cell_tower, size: 20),
                const SizedBox(width: 8),
                const Text('Hotspot', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                  '$clientCount client${clientCount == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const Divider(height: 20),

            // DMR section
            const Text('DMR', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _EnabledBadge(label: 'DMR', enabled: config.dmr.enabled),
                _InfoChip(label: 'CC ${config.dmr.colorcode}'),
                _InfoChip(label: config.dmr.masterServer),
                if (config.dmr.dmrId > 0)
                  _InfoChip(label: 'ID ${config.dmr.dmrId}'),
              ],
            ),
            const SizedBox(height: 12),

            // YSF section
            const Text('YSF', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _EnabledBadge(label: 'YSF', enabled: config.ysf.enabled),
                _InfoChip(label: config.ysf.reflector),
                if (config.ysf.suffix.isNotEmpty)
                  _InfoChip(label: config.ysf.suffix),
              ],
            ),
            const SizedBox(height: 12),

            // Cross-mode
            const Text('Cross-Mode', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _EnabledBadge(label: 'YSF2DMR', enabled: config.ysf2dmr.enabled),
                _EnabledBadge(label: 'DMR2YSF', enabled: config.dmr2ysf.enabled),
              ],
            ),
            const SizedBox(height: 16),

            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onManage,
                child: const Text('Manage'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -- Hotspot manage bottom sheet --

class _HotspotManageSheet extends StatefulWidget {
  final HotspotConfig config;
  final String deviceHost;
  const _HotspotManageSheet({required this.config, required this.deviceHost});

  @override
  State<_HotspotManageSheet> createState() => _HotspotManageSheetState();
}

class _HotspotManageSheetState extends State<_HotspotManageSheet> {
  late bool _dmrEnabled;
  late bool _ysfEnabled;
  late bool _ysf2dmrEnabled;
  late bool _dmr2ysfEnabled;
  late TextEditingController _dmrCcCtl;
  late TextEditingController _dmrMasterCtl;
  late TextEditingController _dmrIdCtl;
  late TextEditingController _ysfReflectorCtl;
  late TextEditingController _ysfSuffixCtl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _dmrEnabled = widget.config.dmr.enabled;
    _ysfEnabled = widget.config.ysf.enabled;
    _ysf2dmrEnabled = widget.config.ysf2dmr.enabled;
    _dmr2ysfEnabled = widget.config.dmr2ysf.enabled;
    _dmrCcCtl = TextEditingController(text: widget.config.dmr.colorcode.toString());
    _dmrMasterCtl = TextEditingController(text: widget.config.dmr.masterServer);
    _dmrIdCtl = TextEditingController(
      text: widget.config.dmr.dmrId > 0 ? widget.config.dmr.dmrId.toString() : '',
    );
    _ysfReflectorCtl = TextEditingController(text: widget.config.ysf.reflector);
    _ysfSuffixCtl = TextEditingController(text: widget.config.ysf.suffix);
  }

  @override
  void dispose() {
    _dmrCcCtl.dispose();
    _dmrMasterCtl.dispose();
    _dmrIdCtl.dispose();
    _ysfReflectorCtl.dispose();
    _ysfSuffixCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final api = OpenRigApiClient(host: widget.deviceHost, port: 7373);
    final updated = HotspotConfig(
      dmr: DmrConfig(
        enabled: _dmrEnabled,
        colorcode: int.tryParse(_dmrCcCtl.text) ?? widget.config.dmr.colorcode,
        masterServer: _dmrMasterCtl.text.trim(),
        password: widget.config.dmr.password,
        talkgroups: widget.config.dmr.talkgroups,
        dmrId: int.tryParse(_dmrIdCtl.text) ?? widget.config.dmr.dmrId,
      ),
      ysf: YsfConfig(
        enabled: _ysfEnabled,
        reflector: _ysfReflectorCtl.text.trim(),
        description: widget.config.ysf.description,
        suffix: _ysfSuffixCtl.text.trim(),
      ),
      ysf2dmr: CrossModeConfig(
        enabled: _ysf2dmrEnabled,
        talkgroup: widget.config.ysf2dmr.talkgroup,
        room: widget.config.ysf2dmr.room,
      ),
      dmr2ysf: CrossModeConfig(
        enabled: _dmr2ysfEnabled,
        talkgroup: widget.config.dmr2ysf.talkgroup,
        room: widget.config.dmr2ysf.room,
      ),
    );
    try {
      await api.updateHotspot(updated);
      if (mounted) Navigator.of(context).pop();
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
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Manage Hotspot', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),

            // DMR
            SwitchListTile(
              title: const Text('DMR'),
              value: _dmrEnabled,
              onChanged: (v) => setState(() {
                _dmrEnabled = v;
                if (!v) _dmr2ysfEnabled = false;
              }),
              contentPadding: EdgeInsets.zero,
            ),
            if (_dmrEnabled) ...[
              TextField(
                controller: _dmrIdCtl,
                decoration: const InputDecoration(labelText: 'DMR ID', isDense: true),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _dmrCcCtl,
                decoration: const InputDecoration(labelText: 'Color Code', isDense: true),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _dmrMasterCtl,
                decoration: const InputDecoration(labelText: 'Master Server', isDense: true),
              ),
            ],
            const SizedBox(height: 8),

            // YSF
            SwitchListTile(
              title: const Text('YSF'),
              value: _ysfEnabled,
              onChanged: (v) => setState(() {
                _ysfEnabled = v;
                if (!v) _ysf2dmrEnabled = false;
              }),
              contentPadding: EdgeInsets.zero,
            ),
            if (_ysfEnabled) ...[
              TextField(
                controller: _ysfReflectorCtl,
                decoration: const InputDecoration(labelText: 'Reflector', isDense: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ysfSuffixCtl,
                decoration: const InputDecoration(labelText: 'Suffix', isDense: true),
              ),
            ],
            const SizedBox(height: 8),

            // Cross-mode
            if (_ysfEnabled)
              SwitchListTile(
                title: const Text('YSF \u2192 DMR'),
                subtitle: const Text('Bridge YSF traffic to DMR', style: TextStyle(fontSize: 11)),
                value: _ysf2dmrEnabled,
                onChanged: (v) => setState(() => _ysf2dmrEnabled = v),
                contentPadding: EdgeInsets.zero,
              ),
            if (_dmrEnabled)
              SwitchListTile(
                title: const Text('DMR \u2192 YSF'),
                subtitle: const Text('Bridge DMR traffic to YSF', style: TextStyle(fontSize: 11)),
                value: _dmr2ysfEnabled,
                onChanged: (v) => setState(() => _dmr2ysfEnabled = v),
                contentPadding: EdgeInsets.zero,
              ),
            if (!_ysfEnabled && !_dmrEnabled)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('Enable DMR or YSF to configure cross-mode bridging.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -- Rig card --

class _RigCard extends StatelessWidget {
  const _RigCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.settings_remote, size: 20),
                SizedBox(width: 8),
                Text('Rig Control', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _EnabledBadge(label: 'rigctld', enabled: true),
              ],
            ),
            const SizedBox(height: 8),
            const _InfoRow(label: 'Status', value: 'Active on port 4532'),
          ],
        ),
      ),
    );
  }
}

// -- Quick actions card --

class _QuickActionsCard extends StatelessWidget {
  final VoidCallback onRestart;
  final VoidCallback onReboot;
  final VoidCallback onShutdown;
  const _QuickActionsCard({required this.onRestart, required this.onReboot, required this.onShutdown});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.flash_on, size: 20),
                SizedBox(width: 8),
                Text('Quick Actions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRestart,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Restart Services'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: 'Coming soon',
                    child: OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('Web UI'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onReboot,
                icon: const Icon(Icons.power_settings_new, color: Colors.orange),
                label: const Text('Reboot Device',
                    style: TextStyle(color: Colors.orange)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.orange),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onShutdown,
                icon: const Icon(Icons.power_off, color: Colors.red),
                label: const Text('Shutdown Device',
                    style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -- Shared helper widgets --

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _EnabledBadge extends StatelessWidget {
  final String label;
  final bool enabled;
  const _EnabledBadge({required this.label, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: enabled ? Colors.green.withAlpha(40) : Colors.grey.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled ? Colors.green.withAlpha(100) : Colors.grey.withAlpha(60),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: enabled ? Colors.green : Colors.grey,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  const _InfoChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}

// -- Network card --

class _NetworkCard extends StatelessWidget {
  final NetworkStatus network;
  const _NetworkCard({required this.network});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  network.mode == 'ethernet' ? Icons.cable : Icons.wifi,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text('Network',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Icon(
                  network.connected ? Icons.circle : Icons.circle_outlined,
                  size: 10,
                  color: network.connected
                      ? Colors.green
                      : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const Divider(height: 20),
            _InfoRow(label: 'Mode', value: network.mode),
            if (network.ssid.isNotEmpty)
              _InfoRow(label: 'SSID', value: network.ssid),
            if (network.ip.isNotEmpty)
              _InfoRow(label: 'IP', value: network.ip),
            if (network.networkInterface.isNotEmpty)
              _InfoRow(label: 'Interface', value: network.networkInterface),
            if (network.mode == 'wifi' && network.signalDbm != 0)
              _InfoRow(label: 'Signal', value: '${network.signalDbm} dBm'),
          ],
        ),
      ),
    );
  }
}

// -- WiFi card + manage sheet --

class _WifiCard extends StatelessWidget {
  final List<WifiNetwork> networks;
  final String deviceHost;
  const _WifiCard({required this.networks, required this.deviceHost});

  void _manage(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WifiManageSheet(
        networks: networks,
        deviceHost: deviceHost,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi_lock, size: 20),
                const SizedBox(width: 8),
                const Text('WiFi Networks',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(
                  '${networks.length} configured',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const Divider(height: 20),
            if (networks.isEmpty)
              Text('No networks configured.',
                  style: TextStyle(color: colorScheme.onSurfaceVariant))
            else
              ...networks.map((n) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(n.ssid,
                              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
                        ),
                        Text('P${n.priority}',
                            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  )),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () => _manage(context),
                child: const Text('Manage'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiManageSheet extends StatefulWidget {
  final List<WifiNetwork> networks;
  final String deviceHost;
  const _WifiManageSheet({required this.networks, required this.deviceHost});

  @override
  State<_WifiManageSheet> createState() => _WifiManageSheetState();
}

class _WifiManageSheetState extends State<_WifiManageSheet> {
  late List<WifiNetwork> _networks;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _networks = List.of(widget.networks);
  }

  void _removeNetwork(int index) {
    setState(() => _networks.removeAt(index));
  }

  void _showAddDialog() {
    final ssidCtl = TextEditingController();
    final passCtl = TextEditingController();
    final prioCtl = TextEditingController(text: '${_networks.length + 1}');
    var scanned = <ScannedNetwork>[];
    var scanning = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> scan() async {
            setDialogState(() => scanning = true);
            final api = OpenRigApiClient(host: widget.deviceHost, port: 7373);
            try {
              scanned = await api.scanWifi();
            } catch (_) {
              scanned = [];
            } finally {
              api.dispose();
              if (ctx.mounted) setDialogState(() => scanning = false);
            }
          }

          return AlertDialog(
            title: const Text('Add WiFi Network'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: scanning ? null : scan,
                        icon: scanning
                            ? const SizedBox(
                                width: 14, height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_find, size: 16),
                        label: const Text('Scan'),
                      ),
                    ],
                  ),
                  if (scanned.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: scanned.map((n) => ActionChip(
                        label: Text(n.ssid, style: const TextStyle(fontSize: 12)),
                        avatar: Icon(Icons.wifi, size: 14,
                            color: n.signal > -60 ? Colors.green : Colors.orange),
                        onPressed: () => setDialogState(() => ssidCtl.text = n.ssid),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: ssidCtl,
                    decoration: const InputDecoration(labelText: 'SSID'),
                    autofocus: true,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passCtl,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: prioCtl,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('CANCEL'),
              ),
              FilledButton(
                onPressed: () {
                  final ssid = ssidCtl.text.trim();
                  if (ssid.isEmpty) return;
                  final priority = int.tryParse(prioCtl.text.trim()) ?? _networks.length + 1;
                  final password = passCtl.text;
                  setState(() {
                    _networks.add(WifiNetwork(
                      ssid: ssid,
                      security: password.isNotEmpty ? 'wpa2' : 'open',
                      priority: priority,
                      password: password.isNotEmpty ? password : null,
                    ));
                  });
                  Navigator.of(ctx).pop();
                },
                child: const Text('ADD'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final api = OpenRigApiClient(host: widget.deviceHost, port: 7373);
    try {
      await api.updateWifi(_networks);
      if (mounted) Navigator.of(context).pop();
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
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Manage WiFi',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            if (_networks.isEmpty)
              Text('No networks configured.',
                  style: TextStyle(color: colorScheme.onSurfaceVariant))
            else
              ...List.generate(_networks.length, (i) {
                final n = _networks[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi, size: 18),
                  title: Text(n.ssid, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '${n.security}  priority ${n.priority}',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, size: 20, color: colorScheme.error),
                    onPressed: () => _removeNetwork(i),
                  ),
                );
              }),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _showAddDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Network'),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
