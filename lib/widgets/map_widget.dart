import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple;

class MapLocation {
  final double lat;
  final double lon;
  final String callsign;
  const MapLocation(
      {required this.lat, required this.lon, required this.callsign});
}

/// Shows a native Apple Maps view (iOS) centered on the station being looked up.
/// Falls back to a placeholder on non-iOS platforms.
class MapWidget extends StatefulWidget {
  final ValueNotifier<MapLocation?> location;

  const MapWidget({super.key, required this.location});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget>
    with SingleTickerProviderStateMixin {
  apple.AppleMapController? _mapController;
  late final AnimationController _animController;
  Animation<double>? _latAnim;
  Animation<double>? _lonAnim;

  // Tracks the current map center for animation start point.
  apple.LatLng? _currentCenter;
  // Marker state
  apple.LatLng? _markerPos;
  String _markerLabel = '';
  // Zoom range for current fly-to animation.
  double _animStartZoom = 6.0;
  double _animEndZoom = 6.0;
  double _animMinZoom = 6.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..addListener(_onAnimTick);
    widget.location.addListener(_onLocationChanged);
  }

  @override
  void dispose() {
    _animController.dispose();
    widget.location.removeListener(_onLocationChanged);
    super.dispose();
  }

  void _onAnimTick() {
    if (_latAnim == null || _lonAnim == null) return;
    final t = _animController.value;

    // Parabolic zoom arc: dips to _animMinZoom at t=0.5, recovers to _animEndZoom
    final zoomDip = (_animStartZoom - _animMinZoom) * math.sin(math.pi * t);
    final zoom = _animStartZoom - zoomDip +
        (_animEndZoom - _animStartZoom) * t;

    final pos = apple.LatLng(_latAnim!.value, _lonAnim!.value);
    _currentCenter = pos;

    _mapController?.moveCamera(
      apple.CameraUpdate.newLatLngZoom(pos, zoom),
    );
  }

  void _onLocationChanged() {
    final loc = widget.location.value;
    if (loc == null) return;

    final target = apple.LatLng(loc.lat, loc.lon);
    setState(() {
      _markerPos = target;
      _markerLabel = loc.callsign;
    });

    final from = _currentCenter;
    if (from == null) {
      _currentCenter = target;
      _mapController?.moveCamera(
        apple.CameraUpdate.newLatLngZoom(target, 6),
      );
      return;
    }

    // Distance in km (Haversine) determines zoom arc
    final distKm = _haversineKm(
        from.latitude, from.longitude, target.latitude, target.longitude);

    double minZoom;
    Duration duration;
    if (distKm > 8000) {
      minZoom = 2.5;
      duration = const Duration(milliseconds: 2800);
    } else if (distKm > 4000) {
      minZoom = 3.0;
      duration = const Duration(milliseconds: 2400);
    } else if (distKm > 2000) {
      minZoom = 3.5;
      duration = const Duration(milliseconds: 2000);
    } else if (distKm > 800) {
      minZoom = 4.0;
      duration = const Duration(milliseconds: 1500);
    } else if (distKm > 200) {
      minZoom = 4.5;
      duration = const Duration(milliseconds: 1000);
    } else {
      minZoom = 5.5;
      duration = const Duration(milliseconds: 700);
    }

    _animStartZoom = 6.0;
    _animEndZoom = 6.0;
    _animMinZoom = minZoom;
    _animController.duration = duration;

    _latAnim = Tween<double>(begin: from.latitude, end: target.latitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
    _lonAnim = Tween<double>(begin: from.longitude, end: target.longitude)
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));
    _animController.forward(from: 0);
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: const Center(child: Text('Apple Maps requires iOS')),
      );
    }

    if (_markerPos == null) {
      return Container(
        color: const Color(0xFF1a1a1a),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 32, color: Colors.grey.shade700),
              const SizedBox(height: 8),
              Text(
                'Look up a callsign\nto see their location',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    final annotations = <apple.Annotation>{
      apple.Annotation(
        annotationId: apple.AnnotationId('station'),
        position: _markerPos!,
        infoWindow: apple.InfoWindow(title: _markerLabel),
      ),
    };

    return Stack(
      children: [
        apple.AppleMap(
          initialCameraPosition: apple.CameraPosition(
            target: _markerPos!,
            zoom: 6,
          ),
          annotations: annotations,
          myLocationEnabled: false,
          onMapCreated: (controller) {
            _mapController = controller;
          },
        ),
        // Callsign overlay
        Positioned(
          top: 6,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(160),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _markerLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
