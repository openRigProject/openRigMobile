import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openrig_mobile/connection_state.dart';
import 'package:openrig_mobile/main.dart';
import 'package:openrig_mobile/screens/discovery_screen.dart';
import 'package:openrig_mobile/screens/rig_screen.dart';
import 'package:openrig_mobile/screens/spots_screen.dart';
import 'package:openrig_mobile/screens/log_screen.dart';
import 'package:openrig_mobile/screens/device_screen.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('Discovery screen renders with search and manual button', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(
      MaterialApp(
        home: DiscoveryScreen(appState: appState),
        routes: {'/home': (_) => HomeScreen(appState: appState)},
      ),
    );
    await tester.pump();

    expect(find.text('openRig Mobile'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
  });

  testWidgets('HomeScreen renders with four navigation tabs and settings icon', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: HomeScreen(appState: appState),
      ),
    );

    expect(find.text('openRig Mobile'), findsOneWidget);
    expect(find.text('Spots'), findsOneWidget);
    expect(find.text('Rig Control'), findsOneWidget);
    expect(find.text('Log'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsWidgets);
  });

  testWidgets('Device screen shows no-device message when disconnected', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(_testApp(DeviceScreen(appState: appState)));

    expect(find.text('No device selected'), findsOneWidget);
  });

  testWidgets('Spots screen shows connect prompt when not connected', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(_testApp(SpotsScreen(appState: appState)));

    expect(find.text('DX Cluster not connected'), findsOneWidget);
    expect(find.text('Configure & Connect'), findsOneWidget);
  });

  testWidgets('Rig screen shows not-connected banner by default', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(_testApp(RigScreen(appState: appState)));
    await tester.pump();

    expect(find.text('Not connected — no rig linked'), findsOneWidget);
    expect(find.text('PTT'), findsOneWidget);
    expect(find.text('USB'), findsOneWidget);
  });

  testWidgets('Log screen shows empty state and FAB', (WidgetTester tester) async {
    final appState = AppConnectionState();
    final tempDir = Directory.systemTemp.createTempSync('openrig_test_');
    final logPath = '${tempDir.path}/test_log.adi';

    await tester.pumpWidget(_testApp(LogScreen(appState: appState, logPath: logPath)));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('No QSOs logged yet'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    tempDir.deleteSync(recursive: true);
  });
}
