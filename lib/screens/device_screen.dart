import 'dart:async';
import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart' hide ChangeNotifier;

import '../connection_state.dart';
import '../services/aprs_carplay_channel.dart';
import '../services/native_discovery.dart';
import '../widgets/map_widget.dart';
import 'log_screen.dart' show QsoPreFill;

class DeviceScreen extends StatefulWidget {
  final AppConnectionState appState;
  final void Function(QsoPreFill preFill)? onLogQso;
  final AprsCarPlayChannel? carPlayChannel;

  const DeviceScreen({super.key, required this.appState, this.onLogQso, this.carPlayChannel});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  OpenRigHotspotClient? _client;
  DeviceStatus? _status;
  HotspotConfig? _hotspot;
  NetworkStatus? _network;
  List<WifiNetwork>? _wifiNetworks;
  bool _loading = false;
  String? _error;

  // Last Heard state (inline)
  StreamSubscription<HotspotLastHeardEntry>? _lastHeardSub;
  final List<HotspotLastHeardEntry> _lastHeard = [];
  final ValueNotifier<MapLocation?> _mapLocation = ValueNotifier(null);

  // QRZ callsign lookup with cache
  QrzXmlClient? _qrzClient;
  CallsignInfo? _callsignInfo;
  String? _lastLookedUp;
  final Map<String, CallsignInfo> _callsignCache = {};

  @override
  void initState() {
    super.initState();
    _loadDevice();
  }

  @override
  void didUpdateWidget(DeviceScreen old) {
    super.didUpdateWidget(old);
    if (widget.appState.device?.host != old.appState.device?.host) {
      _disposeClient();
      _loadDevice();
    }
  }

  @override
  void dispose() {
    _disposeClient();
    _mapLocation.dispose();
    super.dispose();
  }

  void _disposeClient() {
    _lastHeardSub?.cancel();
    _lastHeardSub = null;
    _lastHeard.clear();
    _mapLocation.value = null;
    _qrzClient?.dispose();
    _qrzClient = null;
    _callsignInfo = null;
    _lastLookedUp = null;
    _client?.dispose();
    _client = null;
    _status = null;
    _hotspot = null;
    _network = null;
    _wifiNetworks = null;
  }

  void _disconnect() {
    widget.carPlayChannel?.clearLastHeard();
    _disposeClient();
    widget.appState.disconnectDevice();
    if (mounted) setState(() {});
  }

  Future<void> _loadDevice() async {
    final device = widget.appState.device;
    if (device == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    _lastHeardSub?.cancel();
    _client?.dispose();
    final client = OpenRigHotspotClient(host: device.host);
    _client = client;

    try {
      final status = await client.getStatus();
      NetworkStatus? network;
      try { network = await client.getNetworkStatus(); } catch (_) {}
      List<WifiNetwork>? wifiNetworks;
      try { wifiNetworks = await client.getWifi(); } catch (_) {}
      HotspotConfig? hotspot;
      if (status.type == 'hotspot') {
        hotspot = await client.getHotspotConfig();
      }
      if (!mounted) return;
      setState(() {
        _status = status;
        _network = network;
        _wifiNetworks = wifiNetworks;
        _hotspot = hotspot;
        _loading = false;
      });
      // Start last heard stream for hotspots
      if (status.type == 'hotspot') {
        _lastHeardSub = client.streamLastHeard().listen(_onLastHeardEntry);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onLastHeardEntry(HotspotLastHeardEntry entry) {
    if (!mounted) return;
    setState(() {
      final sameIdx = _lastHeard.indexWhere((e) => e.sameTransmission(entry));
      if (sameIdx >= 0) {
        _lastHeard[sameIdx] = entry;
        return;
      }
      _lastHeard.removeWhere((e) => e.callsign == entry.callsign && e.mode == entry.mode);
      _lastHeard.insert(0, entry);
      if (_lastHeard.length > 50) _lastHeard.removeLast();
    });
    // Look up the new top callsign and push to CarPlay
    if (_lastHeard.isNotEmpty) {
      _pushLastHeardToCarPlay();
      _lookupCallsign(_lastHeard.first.callsign);
    }
  }

  Future<void> _lookupCallsign(String callsign) async {
    if (callsign == _lastLookedUp) return;
    _lastLookedUp = callsign;

    // Check cache first
    final cached = _callsignCache[callsign];
    if (cached != null) {
      _showCallsignInfo(cached);
      return;
    }

    final settings = widget.appState.settings;
    final user = settings?.qrzXmlUser ?? '';
    final pass = settings?.qrzXmlPass ?? '';
    if (user.isEmpty || pass.isEmpty) return;

    _qrzClient ??= QrzXmlClient(username: user, password: pass);

    try {
      final info = await _qrzClient!.lookupCallsign(callsign);
      if (!mounted) return;
      _callsignCache[callsign] = info;
      _showCallsignInfo(info);
    } catch (_) {
      // QRZ lookup failed — leave previous info
    }
  }

  void _showCallsignInfo(CallsignInfo info) {
    // Ignore stale lookups — only update for the most recently requested callsign.
    if (info.call != _lastLookedUp) return;
    setState(() => _callsignInfo = info);
    double? lat, lon;
    if (info.grid.length >= 4) {
      final ll = gridToLatLon(info.grid);
      if (ll != null) {
        lat = ll.lat;
        lon = ll.lon;
        _mapLocation.value = MapLocation(
          lat: ll.lat,
          lon: ll.lon,
          callsign: info.call,
        );
      }
    }
    _pushLastHeardToCarPlay(lat: lat, lon: lon);
  }

  void _pushLastHeardToCarPlay({double? lat, double? lon}) {
    final channel = widget.carPlayChannel;
    if (channel == null || _lastHeard.isEmpty) return;
    final entry = _lastHeard.first;
    final info = _callsignInfo;
    final freqMhz = _hotspot?.rfFrequencyMhz ?? 0.0;
    final locationParts = <String>[];
    if (info != null) {
      if (info.city.isNotEmpty) locationParts.add(info.city);
      if (info.state.isNotEmpty) locationParts.add(info.state);
      if (info.country.isNotEmpty) locationParts.add(info.country);
    }
    channel.updateLastHeard(
      callsign: entry.callsign,
      mode: entry.mode.toUpperCase(),
      info: entry.info,
      duration: entry.duration,
      isActive: entry.isActive,
      name: info?.fullName,
      location: locationParts.join(', '),
      grid: info?.grid,
      lat: lat,
      lon: lon,
      freqMhz: freqMhz,
    );
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
    final client = OpenRigHotspotClient(host: device.host);
    final type = status?.type ?? device.type;
    final services = <String>[];
    if (type == 'hotspot') {
      if (hotspot?.dmr.enabled == true) services.add('dmr');
      if (hotspot?.ysf.enabled == true) {
        services.add('ysf');
        services.add('ysfparrot');
      }
      if (hotspot?.ysf2dmr.enabled == true) services.add('ysf2dmr');
      if (hotspot?.dmr2ysf.enabled == true) services.add('dmr2ysf');
    }
    if (services.isEmpty) services.add('wifi');

    try {
      for (final s in services) {
        await client.restartService(s);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Services restarted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restart failed: $e')),
        );
      }
    } finally {
      client.dispose();
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
    final client = OpenRigHotspotClient(host: device.host);
    try {
      await client.reboot();
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
      client.dispose();
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

  void _openDeviceInfo() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DeviceInfoScreen(
          appState: widget.appState,
          status: _status,
          hotspot: _hotspot,
          network: _network,
          wifiNetworks: _wifiNetworks,
          formatUptime: _formatUptime,
          onRestartServices: () => _restartServices(_hotspot, _status),
          onReboot: _reboot,
          onShowManageHotspot: _hotspot != null
              ? () => _showManageHotspot(_hotspot!)
              : null,
        ),
      ),
    );
  }

  Color _modeColor(String mode) {
    switch (mode.toUpperCase()) {
      case 'DMR':
        return Colors.blue;
      case 'YSF':
        return Colors.orange;
      case 'DSTAR':
      case 'D-STAR':
        return Colors.green;
      case 'NXDN':
        return Colors.purple;
      case 'P25':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _formatTime(String timestamp) {
    final dt = DateTime.tryParse(timestamp);
    if (dt == null) return timestamp;
    final utc = dt.toUtc();
    return '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')}:'
        '${utc.second.toString().padLeft(2, '0')}z';
  }

  void _onTapEntry(HotspotLastHeardEntry entry) {
    _lookupCallsign(entry.callsign);
  }

  void _onLongPressEntry(HotspotLastHeardEntry entry) {
    final colorScheme = Theme.of(context).colorScheme;
    final cached = _callsignCache[entry.callsign];
    final freqMhz = _hotspot?.rfFrequencyMhz ?? 0.0;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.callsign,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              if (cached != null && cached.fullName.isNotEmpty)
                Text(cached.fullName, style: const TextStyle(fontSize: 14)),
              if (cached != null) ...[
                Text(
                  [
                    if (cached.city.isNotEmpty) cached.city,
                    if (cached.state.isNotEmpty) cached.state,
                    if (cached.country.isNotEmpty) cached.country,
                  ].join(', '),
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  Chip(label: Text(entry.mode.toUpperCase())),
                  if (entry.info.isNotEmpty) Chip(label: Text(entry.info)),
                  if (freqMhz > 0)
                    Chip(label: Text('${freqMhz.toStringAsFixed(4)} MHz')),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _logQso(entry);
                  },
                  icon: const Icon(Icons.menu_book),
                  label: const Text('Log QSO'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Also trigger QRZ lookup if not cached
    if (cached == null) _lookupCallsign(entry.callsign);
  }

  void _logQso(HotspotLastHeardEntry entry) {
    final freqMhz = _hotspot?.rfFrequencyMhz ?? 0.0;
    final timeOn = DateTime.tryParse(entry.timestamp)?.toUtc();
    final preFill = QsoPreFill(
      callsign: entry.callsign,
      freqMhz: freqMhz > 0 ? freqMhz : null,
      mode: entry.mode.toUpperCase(),
      timeOn: timeOn,
    );
    widget.onLogQso?.call(preFill);
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.appState.device;

    if (device == null) {
      return _DeviceDiscoveryView(
        onDeviceSelected: (d) {
          widget.appState.setDevice(d);
          widget.appState.connectRig();
          if (mounted) _loadDevice();
        },
        onManualConnect: (host) {
          widget.appState.setManualDevice(host);
          widget.appState.connectRig();
          if (mounted) _loadDevice();
        },
      );
    }

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Connecting to ${device.host}...'),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Back'),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('Failed to connect to ${device.host}'),
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _loadDevice(),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Back'),
            ),
          ],
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final callsign = _status?.callsign ?? device.callsign;
    final label = callsign.isNotEmpty ? callsign : device.host;

    // Main view: Map + Last Heard stream with bottom device info button
    return Column(
      children: [
        // Back row
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _disconnect,
                tooltip: 'Change Device',
              ),
              Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_status != null)
                _TypeBadge(type: _status!.type),
            ],
          ),
        ),
        const Divider(height: 1),
        // Map — top portion
        SizedBox(
          height: 200,
          child: MapWidget(location: _mapLocation),
        ),
        // Callsign info bar
        if (_callsignInfo != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _callsignInfo!.call,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if (_callsignInfo!.fullName.isNotEmpty)
                        Text(_callsignInfo!.fullName, style: const TextStyle(fontSize: 14)),
                      Text(
                        [
                          if (_callsignInfo!.city.isNotEmpty) _callsignInfo!.city,
                          if (_callsignInfo!.state.isNotEmpty) _callsignInfo!.state,
                          if (_callsignInfo!.country.isNotEmpty) _callsignInfo!.country,
                        ].join(', '),
                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (_callsignInfo!.grid.isNotEmpty)
                  Chip(label: Text(_callsignInfo!.grid, style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
        const Divider(height: 1),
        // Last Heard list
        Expanded(
          child: _lastHeard.isEmpty
              ? Center(
                  child: Text(
                    'Waiting for activity\u2026',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  itemCount: _lastHeard.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = _lastHeard[index];
                    final mode = entry.mode.toUpperCase();
                    final color = _modeColor(mode);

                    return ListTile(
                      onTap: () => _onTapEntry(entry),
                      onLongPress: () => _onLongPressEntry(entry),
                      leading: Container(
                        width: 48,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withAlpha(40),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          mode,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ),
                      title: Text(
                        entry.callsign,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        entry.info.isNotEmpty
                            ? '${entry.info}${entry.isActive ? '  LIVE' : '  ${entry.duration}'}'
                            : entry.isActive
                                ? 'LIVE'
                                : entry.duration,
                      ),
                      trailing: Text(
                        _formatTime(entry.timestamp),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      tileColor: entry.isActive
                          ? colorScheme.primary.withAlpha(20)
                          : null,
                    );
                  },
                ),
        ),
        // Bottom device info button
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _openDeviceInfo,
                icon: const Icon(Icons.info_outline),
                label: const Text('Device Info'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// -- Device Info Screen (pushed from main view) --

class _DeviceInfoScreen extends StatelessWidget {
  final AppConnectionState appState;
  final DeviceStatus? status;
  final HotspotConfig? hotspot;
  final NetworkStatus? network;
  final List<WifiNetwork>? wifiNetworks;
  final String Function(int) formatUptime;
  final VoidCallback onRestartServices;
  final VoidCallback onReboot;
  final VoidCallback? onShowManageHotspot;

  const _DeviceInfoScreen({
    required this.appState,
    this.status,
    this.hotspot,
    this.network,
    this.wifiNetworks,
    required this.formatUptime,
    required this.onRestartServices,
    required this.onReboot,
    this.onShowManageHotspot,
  });

  @override
  Widget build(BuildContext context) {
    final device = appState.device;
    final type = status?.type ?? device?.type ?? 'unknown';
    final isHotspot = type == 'hotspot';

    return Scaffold(
      appBar: AppBar(title: const Text('Device Info')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            appState: appState,
            status: status,
            formatUptime: formatUptime,
          ),
          const SizedBox(height: 12),
          if (network != null) ...[
            _NetworkCard(network: network!),
            const SizedBox(height: 12),
          ],
          if (wifiNetworks != null && device != null) ...[
            _WifiCard(
              networks: wifiNetworks!,
              deviceHost: device.host,
            ),
            const SizedBox(height: 12),
          ],
          if (isHotspot && hotspot != null) ...[
            _HotspotCard(
              config: hotspot!,
              onManage: onShowManageHotspot ?? () {},
            ),
            const SizedBox(height: 12),
          ],
          _QuickActionsCard(
            onRestart: onRestartServices,
            onReboot: onReboot,
          ),
        ],
      ),
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
  final VoidCallback onManage;
  const _HotspotCard({required this.config, required this.onManage});

  @override
  Widget build(BuildContext context) {
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
    final client = OpenRigHotspotClient(host: widget.deviceHost);
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
      await client.saveHotspotConfig(updated);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
        setState(() => _saving = false);
      }
    } finally {
      client.dispose();
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
  const _QuickActionsCard({required this.onRestart, required this.onReboot});

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
            final client = OpenRigHotspotClient(host: widget.deviceHost);
            try {
              scanned = await client.scanWifi();
            } catch (_) {
              scanned = [];
            } finally {
              client.dispose();
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
    final client = OpenRigHotspotClient(host: widget.deviceHost);
    try {
      await client.updateWifi(_networks);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
        setState(() => _saving = false);
      }
    } finally {
      client.dispose();
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

// ---------------------------------------------------------------------------
// Inline device discovery (replaces the old standalone DiscoveryScreen)
// ---------------------------------------------------------------------------

class _DeviceDiscoveryView extends StatefulWidget {
  final void Function(OpenRigDevice device) onDeviceSelected;
  final void Function(String host) onManualConnect;

  const _DeviceDiscoveryView({
    required this.onDeviceSelected,
    required this.onManualConnect,
  });

  @override
  State<_DeviceDiscoveryView> createState() => _DeviceDiscoveryViewState();
}

class _DeviceDiscoveryViewState extends State<_DeviceDiscoveryView> {
  NativeDiscovery? _discovery;
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
    _discovery = NativeDiscovery();
    _foundSub = _discovery!.onDeviceFound.listen((device) {
      if (mounted) {
        setState(() {
          _devices[device.host] = device;
          _searching = false;
        });
      }
    });
    _lostSub = _discovery!.onDeviceLost.listen((host) {
      if (mounted) setState(() => _devices.remove(host));
    });
    try {
      await _discovery!.start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _searching = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _foundSub?.cancel();
    _lostSub?.cancel();
    _discovery?.stop();
    super.dispose();
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
          onSubmitted: (v) {
            final trimmed = v.trim();
            if (trimmed.isEmpty) return;
            Navigator.of(ctx).pop();
            widget.onManualConnect(trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isEmpty) return;
              Navigator.of(ctx).pop();
              widget.onManualConnect(trimmed);
            },
            child: const Text('CONNECT'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final deviceList = _devices.values.toList();

    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Auto-discovery unavailable on this device.\nUse manual connection below.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        if (_searching && deviceList.isEmpty && _error == null)
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
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.router_outlined,
                            size: 64, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 16),
                        const Text('No devices found'),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _showManualEntry,
                          icon: const Icon(Icons.edit),
                          label: const Text('Connect Manually'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: deviceList.length,
                    itemBuilder: (context, index) {
                      final d = deviceList[index];
                      return ListTile(
                        leading: Icon(
                          d.hasRigctld
                              ? Icons.settings_remote
                              : Icons.router,
                          color: colorScheme.primary,
                        ),
                        title: Text(
                          d.callsign.isNotEmpty ? d.callsign : d.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text('${d.host}  \u2022  ${d.type}'),
                        trailing: d.hasRigctld
                            ? Chip(
                                label: const Text('rigctld'),
                                backgroundColor: colorScheme.primaryContainer,
                              )
                            : null,
                        onTap: () => widget.onDeviceSelected(d),
                      );
                    },
                  ),
          ),
        if (deviceList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TextButton.icon(
              onPressed: _showManualEntry,
              icon: const Icon(Icons.edit),
              label: const Text('Connect Manually'),
            ),
          ),
      ],
    );
  }
}
