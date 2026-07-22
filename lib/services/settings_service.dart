import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _keyDeviceHost = 'device_host';
  static const _keyDevicePort = 'device_port';
  static const _keyCallsign = 'callsign';
  static const _keyClusterHost = 'cluster_host';
  static const _keyClusterPort = 'cluster_port';
  static const _keyGridSquare = 'grid_square';
  static const _keyQrzApiKey = 'qrz_api_key';
  static const _keyQrzXmlUser = 'qrz_xml_user';
  static const _keyQrzXmlPass = 'qrz_xml_pass';
  static const _keyAprsApiKey = 'aprs_api_key';
  static const _keyAprsTrackedCallsigns = 'aprs_tracked_callsigns';

  late final SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // -- Last connected device --

  String? get deviceHost => _prefs.getString(_keyDeviceHost);
  int get devicePort => _prefs.getInt(_keyDevicePort) ?? 4532;

  Future<void> setDevice(String host, int port) async {
    await _prefs.setString(_keyDeviceHost, host);
    await _prefs.setInt(_keyDevicePort, port);
  }

  Future<void> clearDevice() async {
    await _prefs.remove(_keyDeviceHost);
    await _prefs.remove(_keyDevicePort);
  }

  // -- Callsign --

  String get callsign => _prefs.getString(_keyCallsign) ?? '';

  Future<void> setCallsign(String callsign) async {
    await _prefs.setString(_keyCallsign, callsign);
  }

  // -- Grid Square --

  String get gridSquare => _prefs.getString(_keyGridSquare) ?? '';

  Future<void> setGridSquare(String gridSquare) async {
    await _prefs.setString(_keyGridSquare, gridSquare);
  }

  // -- QRZ Logbook --

  String get qrzApiKey => _prefs.getString(_keyQrzApiKey) ?? '';

  Future<void> setQrzApiKey(String key) async {
    await _prefs.setString(_keyQrzApiKey, key);
  }

  // -- QRZ XML Lookup --

  String get qrzXmlUser => _prefs.getString(_keyQrzXmlUser) ?? '';
  String get qrzXmlPass => _prefs.getString(_keyQrzXmlPass) ?? '';

  Future<void> setQrzXmlCredentials(String user, String pass) async {
    await _prefs.setString(_keyQrzXmlUser, user);
    await _prefs.setString(_keyQrzXmlPass, pass);
  }

  // -- APRS --

  String get aprsApiKey => _prefs.getString(_keyAprsApiKey) ?? '';

  Future<void> setAprsApiKey(String key) async {
    await _prefs.setString(_keyAprsApiKey, key);
  }

  String get aprsTrackedCallsigns =>
      _prefs.getString(_keyAprsTrackedCallsigns) ?? '';

  Future<void> setAprsTrackedCallsigns(String callsigns) async {
    await _prefs.setString(_keyAprsTrackedCallsigns, callsigns);
  }

  // -- DX Cluster node --

  String get clusterHost => _prefs.getString(_keyClusterHost) ?? 'dxc.ve7cc.net';
  int get clusterPort => _prefs.getInt(_keyClusterPort) ?? 23;

  Future<void> setCluster(String host, int port) async {
    await _prefs.setString(_keyClusterHost, host);
    await _prefs.setInt(_keyClusterPort, port);
  }
}
