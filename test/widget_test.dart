import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openrig_mobile/connection_state.dart';
import 'package:openrig_mobile/main.dart';
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
    expect(find.text('Log'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('APRS'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsWidgets);
  });

  testWidgets('Device screen shows discovery view when no device connected', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(_testApp(DeviceScreen(appState: appState)));
    await tester.pump();

    // Should show manual connect option (discovery may fail in test env)
    expect(find.textContaining('Connect Manually').evaluate().isNotEmpty ||
           find.text('Searching for openRig devices...').evaluate().isNotEmpty,
        isTrue);
  });

  testWidgets('Spots screen shows connect prompt when not connected', (WidgetTester tester) async {
    final appState = AppConnectionState();
    await tester.pumpWidget(_testApp(SpotsScreen(appState: appState)));

    expect(find.text('DX Cluster not connected'), findsOneWidget);
    expect(find.text('Configure & Connect'), findsOneWidget);
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
