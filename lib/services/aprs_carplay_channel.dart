import 'package:flutter/services.dart';
import 'package:openrig_core/openrig_core.dart';

class AprsCarPlayChannel {
  static const _channel = MethodChannel('com.openrig.mobile/carplay');

  List<AprsStation> _stations = [];
  Map<String, dynamic>? _lastHeardData;

  /// Called by CarPlay when its map center/zoom changes.
  void Function(double lat, double lon, double zoom)? onCarPlayMapMoved;

  AprsCarPlayChannel() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  void updateStations(List<AprsStation> stations) {
    _stations = stations;
    _pushUpdate();
  }

  /// Push a last heard entry (with optional QRZ info and location) to CarPlay.
  void updateLastHeard({
    required String callsign,
    required String mode,
    String info = '',
    String duration = '',
    bool isActive = false,
    String? name,
    String? location,
    String? grid,
    double? lat,
    double? lon,
    double? freqMhz,
  }) {
    _lastHeardData = {
      'callsign': callsign,
      'mode': mode,
      'info': info,
      'duration': duration,
      'isActive': isActive,
      'name': name ?? '',
      'location': location ?? '',
      'grid': grid ?? '',
      'lat': lat ?? 0.0,
      'lon': lon ?? 0.0,
      'freqMhz': freqMhz ?? 0.0,
    };
    _channel.invokeMethod('updateLastHeard', _lastHeardData).catchError((_) {},
        test: (e) => e is MissingPluginException);
  }

  /// Clear last heard data (e.g., when disconnecting from device).
  void clearLastHeard() {
    _lastHeardData = null;
    _channel.invokeMethod('clearLastHeard', null).catchError((_) {},
        test: (e) => e is MissingPluginException);
  }

  /// Sync the phone map center to CarPlay.
  void updateMapCenter(double lat, double lon, double zoom) {
    _channel
        .invokeMethod('updateMapCenter', {'lat': lat, 'lon': lon, 'zoom': zoom})
        .catchError((_) {}, test: (e) => e is MissingPluginException);
  }

  void _pushUpdate() {
    final data = _stations.map((s) => {
      'callsign': s.callsign,
      'lat': s.lat,
      'lon': s.lng,
      'detail': '${s.lat.toStringAsFixed(4)}, ${s.lng.toStringAsFixed(4)}',
      'comment': s.comment,
      'speed': s.speed?.toStringAsFixed(1) ?? '',
      'altitude': s.altitude?.toStringAsFixed(0) ?? '',
      'lastTime': s.lastTime.toIso8601String(),
    }).toList();

    // Ignore MissingPluginException when CarPlay scene isn't connected.
    _channel.invokeMethod('updateStations', data).catchError((_) {},
        test: (e) => e is MissingPluginException);
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'getAprsStations':
        return _stations.map((s) => {
          'callsign': s.callsign,
          'lat': s.lat,
          'lon': s.lng,
          'detail': '${s.lat.toStringAsFixed(4)}, ${s.lng.toStringAsFixed(4)}',
          'comment': s.comment,
          'speed': s.speed?.toStringAsFixed(1) ?? '',
          'altitude': s.altitude?.toStringAsFixed(0) ?? '',
          'lastTime': s.lastTime.toIso8601String(),
        }).toList();
      case 'getLastHeard':
        return _lastHeardData;
      case 'mapCenterChanged':
        final args = call.arguments as Map;
        final lat = (args['lat'] as num).toDouble();
        final lon = (args['lon'] as num).toDouble();
        final zoom = (args['zoom'] as num).toDouble();
        onCarPlayMapMoved?.call(lat, lon, zoom);
        return null;
      default:
        throw MissingPluginException('Not implemented: ${call.method}');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
