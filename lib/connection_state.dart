import 'package:openrig_core/openrig_core.dart';

import 'services/settings_service.dart';

/// Frequency in Hz to a display string like "14.074.000".
String formatFrequency(int hz) {
  final mhz = hz ~/ 1000000;
  final khz = (hz % 1000000) ~/ 1000;
  final sub = hz % 1000;
  return '$mhz.${khz.toString().padLeft(3, '0')}.${sub.toString().padLeft(3, '0')}';
}

/// Frequency in kHz (double) to Hz (int).
int khzToHz(double khz) => (khz * 1000).round();

/// Frequency in MHz (double) to Hz (int).
int mhzToHz(double mhz) => (mhz * 1000000).round();

/// Shared app connection state — active device and multi-rig manager.
class AppConnectionState with ChangeNotifier {
  final SettingsService? settings;
  final RigManager rigManager = RigManager();

  OpenRigDevice? _device;

  AppConnectionState({this.settings}) {
    rigManager.addListener(notifyListeners);
  }

  OpenRigDevice? get device => _device;

  /// Convenience: the active rig's client, or null.
  RigClient? get rigctld => rigManager.activeRig?.client;

  /// Convenience: whether the active rig is connected.
  bool get rigConnected =>
      rigManager.activeRig?.connected ?? false;

  void setDevice(OpenRigDevice device) {
    _device = device;
    settings?.setDevice(device.host, device.rigctldPort ?? 4532);
    if (device.callsign.isNotEmpty) {
      settings?.setCallsign(device.callsign);
    }
    notifyListeners();
  }

  /// Add the device's rigctld as a rig and connect.
  Future<void> connectRig() async {
    if (_device == null) return;
    final host = _device!.host;
    final port = _device!.rigctldPort ?? 4532;
    final id = '$host:$port';
    // Avoid duplicate adds
    final existing = rigManager.rigs.where((r) => r.id == id);
    if (existing.isEmpty) {
      await rigManager.addRig(
        host: host,
        port: port,
        label: _device!.callsign.isNotEmpty
            ? _device!.callsign
            : _device!.name,
      );
    }
  }

  /// Disconnect and remove all rigs.
  Future<void> disconnectRig() async {
    for (final rig in List.of(rigManager.rigs)) {
      rigManager.removeRig(rig.id);
    }
  }

  /// Disconnect from the current device and clear saved settings.
  Future<void> disconnectDevice() async {
    await disconnectRig();
    _device = null;
    settings?.clearDevice();
    notifyListeners();
  }

  /// Connect to a device by manual IP/hostname.
  void setManualDevice(String host) {
    _device = OpenRigDevice(
      name: host,
      host: host,
      port: 7373,
      provisioned: true,
      type: 'unknown',
      callsign: '',
      version: '',
      hasRigctld: true,
      rigctldPort: 4532,
    );
    settings?.setDevice(host, 4532);
    notifyListeners();
  }

  /// Restore last device from settings (for auto-reconnect on launch).
  void restoreFromSettings() {
    if (settings == null) return;
    final host = settings!.deviceHost;
    if (host == null || host.isEmpty) return;
    final port = settings!.devicePort;
    _device = OpenRigDevice(
      name: host,
      host: host,
      port: 7373,
      provisioned: true,
      type: 'unknown',
      callsign: settings!.callsign,
      version: '',
      hasRigctld: true,
      rigctldPort: port,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    rigManager.removeListener(notifyListeners);
    rigManager.dispose();
    super.dispose();
  }
}
