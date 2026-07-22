import 'dart:async';

import 'package:flutter/material.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple;
import 'package:openrig_core/openrig_core.dart';

import '../connection_state.dart';
import '../services/aprs_carplay_channel.dart' show AprsCarPlayChannel;

/// Maps geographic regions to common amateur radio callsign prefixes.
/// Used for area browsing when no specific callsigns are tracked.
List<String> _prefixesForArea(double lat, double lon) {
  // North America
  if (lat >= 24 && lat <= 50 && lon >= -130 && lon <= -60) {
    if (lat >= 40 && lon >= -75) return ['W1*', 'W2*', 'K1*', 'K2*'];
    if (lat >= 35 && lon >= -85) return ['W3*', 'W4*', 'K3*', 'K4*'];
    if (lat >= 35 && lon >= -100) return ['W4*', 'W5*', 'K4*', 'K5*'];
    if (lat >= 40 && lon >= -100) return ['W8*', 'W9*', 'K8*', 'K9*'];
    if (lat >= 35 && lon >= -115) return ['W0*', 'W5*', 'K0*', 'K5*'];
    return ['W6*', 'W7*', 'K6*', 'K7*'];
  }
  // Canada
  if (lat >= 42 && lat <= 75 && lon >= -141 && lon <= -52) {
    return ['VE*', 'VA*'];
  }
  // Europe
  if (lat >= 35 && lat <= 72 && lon >= -12 && lon <= 45) {
    if (lon < 5) return ['G*', 'M*', 'EI*', 'F*'];
    if (lon < 15) return ['DL*', 'PA*', 'ON*', 'HB*'];
    if (lon < 25) return ['I*', 'OE*', 'OK*', 'SP*'];
    return ['OH*', 'SM*', 'LA*', 'ES*'];
  }
  // Japan
  if (lat >= 24 && lat <= 46 && lon >= 123 && lon <= 146) {
    return ['JA*', 'JH*', 'JR*'];
  }
  // Australia
  if (lat >= -45 && lat <= -10 && lon >= 112 && lon <= 155) {
    return ['VK*'];
  }
  // South America
  if (lat >= -56 && lat <= 13 && lon >= -82 && lon <= -34) {
    return ['LU*', 'PY*', 'CE*'];
  }
  // Fallback
  return ['W*', 'K*'];
}

class AprsScreen extends StatefulWidget {
  final AppConnectionState appState;
  final AprsCarPlayChannel carPlayChannel;

  const AprsScreen({super.key, required this.appState, required this.carPlayChannel});

  @override
  State<AprsScreen> createState() => _AprsScreenState();
}

class _AprsScreenState extends State<AprsScreen>
    with AutomaticKeepAliveClientMixin {
  List<AprsStation> _stations = [];
  List<String> _trackedCallsigns = [];
  AprsFiClient? _client;
  Timer? _pollTimer;
  Timer? _browseDebounce;
  apple.AppleMapController? _mapController;
  final _searchCtrl = TextEditingController();
  bool _loading = false;
  bool _browsing = false;
  apple.LatLng? _lastBrowseCenter;
  apple.CameraPosition? _lastCameraPosition;
  AprsCarPlayChannel get _carPlayChannel => widget.carPlayChannel;

  @override
  bool get wantKeepAlive => true;

  bool get _isBrowseMode => _trackedCallsigns.isEmpty;

  bool _syncingFromCarPlay = false;

  @override
  void initState() {
    super.initState();
    _carPlayChannel.onCarPlayMapMoved = _onCarPlayMapMoved;
    final s = widget.appState.settings;
    if (s != null) {
      final apiKey = s.aprsApiKey;
      if (apiKey.isNotEmpty) {
        _client = AprsFiClient(apiKey: apiKey);
      }
      final tracked = s.aprsTrackedCallsigns;
      if (tracked.isNotEmpty) {
        _trackedCallsigns = tracked
            .split(',')
            .map((c) => c.trim().toUpperCase())
            .where((c) => c.isNotEmpty)
            .toList();
      }
    }
    if (_client != null && _trackedCallsigns.isNotEmpty) {
      _fetchStations();
    }
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_isBrowseMode) {
        _browseArea();
      } else {
        _fetchStations();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _browseDebounce?.cancel();
    _client?.dispose();
    _carPlayChannel.onCarPlayMapMoved = null;
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchStations() async {
    if (_client == null || _trackedCallsigns.isEmpty) return;
    setState(() => _loading = true);
    try {
      final stations = await _client!.getLocations(_trackedCallsigns);
      if (mounted) {
        setState(() {
          _stations = stations;
          _browsing = false;
          _loading = false;
        });
        _carPlayChannel.updateStations(stations);
        _fitStationsOnMap(stations);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('APRS fetch failed: $e')),
        );
      }
    }
  }

  void _fitStationsOnMap(List<AprsStation> stations) {
    if (stations.isEmpty || _mapController == null) return;
    if (stations.length == 1) {
      _mapController!.moveCamera(apple.CameraUpdate.newLatLngZoom(
        apple.LatLng(stations.first.lat, stations.first.lng),
        10,
      ));
    } else {
      double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
      for (final s in stations) {
        if (s.lat < minLat) minLat = s.lat;
        if (s.lat > maxLat) maxLat = s.lat;
        if (s.lng < minLon) minLon = s.lng;
        if (s.lng > maxLon) maxLon = s.lng;
      }
      _mapController!.moveCamera(apple.CameraUpdate.newLatLngBounds(
        apple.LatLngBounds(
          southwest: apple.LatLng(minLat, minLon),
          northeast: apple.LatLng(maxLat, maxLon),
        ),
        40,
      ));
    }
  }

  void _onCameraMove(apple.CameraPosition position) {
    _lastCameraPosition = position;
  }

  void _onCameraIdle() {
    if (_syncingFromCarPlay) return;
    _syncCameraToCarPlay();
    if (_isBrowseMode && _client != null) {
      _browseDebounce?.cancel();
      _browseDebounce = Timer(const Duration(seconds: 2), _browseArea);
    }
  }

  void _syncCameraToCarPlay() {
    final pos = _lastCameraPosition;
    if (pos == null) return;
    _carPlayChannel.updateMapCenter(
      pos.target.latitude,
      pos.target.longitude,
      pos.zoom,
    );
  }

  void _onCarPlayMapMoved(double lat, double lon, double zoom) {
    if (!mounted || _mapController == null) return;
    _syncingFromCarPlay = true;
    final target = apple.LatLng(lat, lon);
    _lastCameraPosition = apple.CameraPosition(target: target, zoom: zoom);
    _mapController!.moveCamera(
      apple.CameraUpdate.newLatLngZoom(target, zoom),
    );
    Future.delayed(const Duration(milliseconds: 500), () {
      _syncingFromCarPlay = false;
    });
  }

  Future<void> _browseArea() async {
    if (_client == null || !_isBrowseMode) return;

    final pos = _lastCameraPosition;
    if (pos == null) return;

    final center = pos.target;

    // Skip if center hasn't moved significantly
    if (_lastBrowseCenter != null) {
      final dLat = (center.latitude - _lastBrowseCenter!.latitude).abs();
      final dLon = (center.longitude - _lastBrowseCenter!.longitude).abs();
      if (dLat < 0.5 && dLon < 0.5 && _stations.isNotEmpty) return;
    }
    _lastBrowseCenter = center;

    // Estimate visible bounds from zoom level (~degrees per zoom level)
    final latSpan = 180.0 / (1 << pos.zoom.round().clamp(1, 20));
    final lonSpan = 360.0 / (1 << pos.zoom.round().clamp(1, 20));

    final prefixes = _prefixesForArea(center.latitude, center.longitude);
    setState(() => _loading = true);
    try {
      final stations = await _client!.getLocations(prefixes);
      if (!mounted || !_isBrowseMode) return;

      // Filter to stations within the estimated visible bounds (with padding)
      final padLat = latSpan * 0.7;
      final padLon = lonSpan * 0.7;
      final filtered = stations.where((s) {
        return s.lat >= center.latitude - padLat &&
            s.lat <= center.latitude + padLat &&
            s.lng >= center.longitude - padLon &&
            s.lng <= center.longitude + padLon;
      }).toList();

      setState(() {
        _stations = filtered;
        _browsing = true;
        _loading = false;
      });
      _carPlayChannel.updateStations(filtered);
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _addCallsign() {
    final call = _searchCtrl.text.trim().toUpperCase();
    if (call.isEmpty) return;
    if (_trackedCallsigns.contains(call)) {
      _searchCtrl.clear();
      return;
    }
    setState(() {
      _trackedCallsigns.add(call);
      _browsing = false;
    });
    _searchCtrl.clear();
    widget.appState.settings
        ?.setAprsTrackedCallsigns(_trackedCallsigns.join(','));
    _fetchStations();
  }

  void _removeCallsign(String call) {
    setState(() {
      _trackedCallsigns.remove(call);
      _stations.removeWhere((s) => s.callsign == call);
    });
    widget.appState.settings
        ?.setAprsTrackedCallsigns(_trackedCallsigns.join(','));
    if (_isBrowseMode) {
      _browseArea();
    }
  }

  void _goToMyLocation() {
    final grid = widget.appState.settings?.gridSquare ?? '';
    final pos = gridToLatLon(grid);
    if (pos != null && _mapController != null) {
      _mapController!.moveCamera(
        apple.CameraUpdate.newLatLngZoom(apple.LatLng(pos.lat, pos.lon), 10),
      );
    }
  }

  void _showStationDetail(AprsStation station) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  station.callsign,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_isBrowseMode)
                  FilledButton.tonal(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      setState(() {
                        _trackedCallsigns.add(station.callsign);
                      });
                      widget.appState.settings?.setAprsTrackedCallsigns(
                          _trackedCallsigns.join(','));
                      _fetchStations();
                    },
                    child: const Text('Track'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (station.speed != null && station.speed! > 0)
                  _DetailChip(
                    icon: Icons.speed,
                    label: '${station.speed!.toStringAsFixed(0)} km/h',
                  ),
                if (station.course != null && station.course! > 0)
                  _DetailChip(
                    icon: Icons.explore,
                    label: '${station.course!.toStringAsFixed(0)}\u00b0',
                  ),
                if (station.altitude != null)
                  _DetailChip(
                    icon: Icons.terrain,
                    label: '${station.altitude!.toStringAsFixed(0)} m',
                  ),
                _DetailChip(
                  icon: Icons.access_time,
                  label: _formatRelativeTime(station.lastTime),
                ),
              ],
            ),
            if (station.comment.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                station.comment,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            SizedBox(height: MediaQuery.of(ctx).viewPadding.bottom),
          ],
        ),
      ),
    );
  }

  String _formatRelativeTime(DateTime t) {
    final diff = DateTime.now().toUtc().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // Map station index to a lookup for tap handling
  final Map<String, AprsStation> _stationMap = {};

  Set<apple.Annotation> _buildAnnotations() {
    _stationMap.clear();
    final colorScheme = Theme.of(context).colorScheme;
    final browseHue = HSLColor.fromColor(colorScheme.tertiary).hue;
    final trackHue = HSLColor.fromColor(colorScheme.primary).hue;

    final hue = _browsing ? browseHue : trackHue;
    return _stations.map((s) {
      final id = '${s.callsign}_${s.lat}_${s.lng}';
      _stationMap[id] = s;
      return apple.Annotation(
        annotationId: apple.AnnotationId(id),
        position: apple.LatLng(s.lat, s.lng),
        infoWindow: apple.InfoWindow(
          title: s.callsign,
          snippet: s.comment.isNotEmpty ? s.comment : _formatRelativeTime(s.lastTime),
        ),
        icon: apple.BitmapDescriptor.markerAnnotationWithHue(hue.toDouble()),
        onTap: () {
          _showStationDetail(s);
        },
      );
    }).toSet();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;

    if (_client == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.my_location,
                size: 64, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('APRS Map Viewer',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Configure your APRS.fi API key in Settings to get started.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Free API keys available at aprs.fi',
              style: TextStyle(
                  fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          // Search bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: _isBrowseMode
                          ? 'Search callsign to track (wildcards: W6*)'
                          : 'Add callsign to track',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    onSubmitted: (_) => _addCallsign(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addCallsign,
                  visualDensity: VisualDensity.compact,
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),

          // Tracked callsign chips or browse mode indicator
          if (_trackedCallsigns.isNotEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: colorScheme.surfaceContainerHigh,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _trackedCallsigns.map((call) {
                  return Chip(
                    label:
                        Text(call, style: const TextStyle(fontSize: 12)),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => _removeCallsign(call),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
            )
          else if (_browsing)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: colorScheme.surfaceContainerHigh,
              child: Row(
                children: [
                  Icon(Icons.explore, size: 14,
                      color: colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Text(
                    'Browsing ${_stations.length} station${_stations.length == 1 ? '' : 's'} in area',
                    style: TextStyle(
                        fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Text(
                    'Pan map to explore',
                    style: TextStyle(
                        fontSize: 11, color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

          // Map
          Expanded(
            child: apple.AppleMap(
              initialCameraPosition: const apple.CameraPosition(
                target: apple.LatLng(39.8283, -98.5795),
                zoom: 4,
              ),
              annotations: _buildAnnotations(),
              myLocationEnabled: false,
              onMapCreated: (controller) {
                _mapController = controller;
                if (_isBrowseMode) {
                  Future.delayed(const Duration(milliseconds: 500), _browseArea);
                }
              },
              onCameraMove: _onCameraMove,
              onCameraIdle: _onCameraIdle,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _goToMyLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DetailChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label,
              style:
                  TextStyle(fontSize: 13, color: colorScheme.onSurface)),
        ],
      ),
    );
  }
}
