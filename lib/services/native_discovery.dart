import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'package:openrig_core/openrig_core.dart' show OpenRigDevice;

/// Native mDNS discovery using Bonsoir (NSNetServiceBrowser on iOS,
/// NsdManager on Android). Replaces the pure-Dart multicast_dns approach
/// which doesn't work on iOS due to port 5353 conflicts.
class NativeDiscovery {
  BonsoirDiscovery? _openrigBrowser;
  BonsoirDiscovery? _rigctldBrowser;

  final _deviceController = StreamController<OpenRigDevice>.broadcast();
  final _lostController = StreamController<String>.broadcast();

  final Map<String, OpenRigDevice> devices = {};
  final Map<String, int> _rigctldPorts = {};

  Stream<OpenRigDevice> get onDeviceFound => _deviceController.stream;
  Stream<String> get onDeviceLost => _lostController.stream;

  Future<void> start() async {
    _openrigBrowser = BonsoirDiscovery(type: '_openrig._tcp');
    await _openrigBrowser!.initialize();
    _openrigBrowser!.eventStream?.listen(_handleOpenrigEvent);
    await _openrigBrowser!.start();

    _rigctldBrowser = BonsoirDiscovery(type: '_rigctld._tcp');
    await _rigctldBrowser!.initialize();
    _rigctldBrowser!.eventStream?.listen(_handleRigctldEvent);
    await _rigctldBrowser!.start();
  }

  void _handleOpenrigEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        event.service.resolve(_openrigBrowser!.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        _addDevice(event.service);
      case BonsoirDiscoveryServiceLostEvent():
        final host = _hostKey(event.service);
        if (devices.containsKey(host)) {
          devices.remove(host);
          _lostController.add(host);
        }
      default:
        break;
    }
  }

  void _handleRigctldEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        event.service.resolve(_rigctldBrowser!.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        final service = event.service;
        final host = _hostKey(service);
        _rigctldPorts[host] = service.port;
        final existing = devices[host];
        if (existing != null) {
          final updated = existing.copyWith(
            hasRigctld: true,
            rigctldPort: service.port,
          );
          devices[host] = updated;
          _deviceController.add(updated);
        }
      default:
        break;
    }
  }

  void _addDevice(BonsoirService service) {
    final host = _hostKey(service);
    final attrs = service.attributes;

    final device = OpenRigDevice(
      name: service.name,
      host: host,
      port: service.port,
      provisioned: attrs['provisioned'] == 'true',
      type: attrs['type'] ?? 'unconfigured',
      callsign: attrs['callsign'] ?? '',
      version: attrs['version'] ?? '',
      hasRigctld: _rigctldPorts.containsKey(host),
      rigctldPort: _rigctldPorts[host],
    );

    devices[host] = device;
    _deviceController.add(device);
  }

  /// Get the best host identifier: prefer IP address, fall back to hostname.
  String _hostKey(BonsoirService service) {
    if (service.hostAddress != null && service.hostAddress!.isNotEmpty) {
      return service.hostAddress!;
    }
    return service.hostname ?? service.name;
  }

  Future<void> stop() async {
    await _openrigBrowser?.stop();
    await _rigctldBrowser?.stop();
    _openrigBrowser = null;
    _rigctldBrowser = null;
    await _deviceController.close();
    await _lostController.close();
  }
}
