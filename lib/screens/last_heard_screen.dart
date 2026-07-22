import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';

import '../widgets/map_widget.dart';

class LastHeardScreen extends StatefulWidget {
  final String host;

  const LastHeardScreen({super.key, required this.host});

  @override
  State<LastHeardScreen> createState() => _LastHeardScreenState();
}

class _LastHeardScreenState extends State<LastHeardScreen> {
  late final OpenRigHotspotClient _client;
  StreamSubscription<HotspotLastHeardEntry>? _sub;
  final List<HotspotLastHeardEntry> _lastHeard = [];
  final ValueNotifier<MapLocation?> _mapLocation = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _client = OpenRigHotspotClient(host: widget.host, port: 7373);
    _sub = _client.streamLastHeard().listen(_onEntry);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _client.dispose();
    _mapLocation.dispose();
    super.dispose();
  }

  void _onEntry(HotspotLastHeardEntry entry) {
    if (!mounted) return;
    setState(() {
      // Same transmission (callsign+mode+timestamp): patch in place.
      final sameIdx =
          _lastHeard.indexWhere((e) => e.sameTransmission(entry));
      if (sameIdx >= 0) {
        _lastHeard[sameIdx] = entry;
        return;
      }
      // New transmission: evict any previous row for this callsign+mode,
      // then prepend.
      _lastHeard
          .removeWhere((e) => e.callsign == entry.callsign && e.mode == entry.mode);
      _lastHeard.insert(0, entry);
      if (_lastHeard.length > 50) _lastHeard.removeLast();
    });
  }

  void _onTapEntry(HotspotLastHeardEntry entry) {
    // Placeholder: if we had grid info for the callsign we would fly the map
    // there via gridToLatLon(). For now this is a no-op until location data
    // is available from the stream or a lookup service.
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Last Heard')),
      body: Column(
        children: [
          // Map — top 40%
          Expanded(
            flex: 2,
            child: MapWidget(location: _mapLocation),
          ),
          // List — bottom 60%
          Expanded(
            flex: 3,
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
                        onTap: () => _onTapEntry(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatTime(String timestamp) {
    final dt = DateTime.tryParse(timestamp);
    if (dt == null) return timestamp;
    final utc = dt.toUtc();
    return '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')}:'
        '${utc.second.toString().padLeft(2, '0')}z';
  }
}
