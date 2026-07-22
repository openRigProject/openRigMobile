import 'package:flutter/services.dart';
import 'package:openrig_core/openrig_core.dart';

class AprsCarPlayChannel {
  static const _channel = MethodChannel('com.openrig.mobile/carplay');

  List<AprsStation> _stations = [];

  /// Called by CarPlay when its map center/zoom changes.
  void Function(double lat, double lon, double zoom)? onCarPlayMapMoved;

  AprsCarPlayChannel() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  void updateStations(List<AprsStation> stations) {
    _stations = stations;
    _pushUpdate();
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
