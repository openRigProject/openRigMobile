import 'package:flutter/material.dart';

import 'connection_state.dart';
import 'services/aprs_carplay_channel.dart';
import 'services/settings_service.dart';
import 'screens/spots_screen.dart';
import 'screens/log_screen.dart' show LogScreen, LogScreenState, QsoPreFill;
import 'screens/device_screen.dart';
import 'screens/aprs_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  runApp(OpenRigMobileApp(settings: settings));
}

class OpenRigMobileApp extends StatefulWidget {
  final SettingsService settings;

  const OpenRigMobileApp({super.key, required this.settings});

  @override
  State<OpenRigMobileApp> createState() => _OpenRigMobileAppState();
}

class _OpenRigMobileAppState extends State<OpenRigMobileApp> {
  late final AppConnectionState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppConnectionState(settings: widget.settings);
    _tryAutoConnect();
  }

  Future<void> _tryAutoConnect() async {
    try {
      _appState.restoreFromSettings();
      if (_appState.device != null) {
        await _appState.connectRig();
      }
    } catch (_) {
      // Device unreachable — clear it so we don't crash on next launch
      _appState.disconnectDevice();
    }
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openRig Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(appState: _appState),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final AppConnectionState appState;

  const HomeScreen({super.key, required this.appState});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final _logKey = GlobalKey<LogScreenState>();
  late final AprsCarPlayChannel _carPlayChannel;

  @override
  void initState() {
    super.initState();
    _carPlayChannel = AprsCarPlayChannel();
  }

  @override
  void dispose() {
    _carPlayChannel.dispose();
    super.dispose();
  }

  void _logQsoFromSpot(QsoPreFill preFill) {
    setState(() => _selectedIndex = 0); // Switch to Log tab
    // Schedule dialog after the frame so the LogScreen is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logKey.currentState?.openNewQsoDialog(preFill: preFill);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      LogScreen(key: _logKey, appState: widget.appState),
      SpotsScreen(
        appState: widget.appState,
        onLogQso: _logQsoFromSpot,
      ),
      DeviceScreen(appState: widget.appState, onLogQso: _logQsoFromSpot),
      AprsScreen(appState: widget.appState, carPlayChannel: _carPlayChannel),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('openRig Mobile'),
        actions: [
          if (widget.appState.device != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                avatar: Icon(
                  widget.appState.rigConnected ? Icons.link : Icons.link_off,
                  size: 16,
                ),
                label: Text(
                  widget.appState.device!.callsign.isNotEmpty
                      ? widget.appState.device!.callsign
                      : widget.appState.device!.host,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(appState: widget.appState),
                ),
              );
            },
          ),
        ],
      ),
      body: screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.menu_book), label: 'Log'),
          NavigationDestination(icon: Icon(Icons.radar), label: 'Spots'),
          NavigationDestination(icon: Icon(Icons.router), label: 'Devices'),
          NavigationDestination(icon: Icon(Icons.my_location), label: 'APRS'),
        ],
      ),
    );
  }
}
