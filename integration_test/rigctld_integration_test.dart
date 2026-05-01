/// Integration tests for RigctldClient against a real rigctld process.
///
/// Uses hamlib model 1 (Dummy rig) — no real hardware required, safe for CI.
///
/// Run with:
///   dart test integration_test/rigctld_integration_test.dart
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:openrig_core/openrig_core.dart';

const _rigctldPort = 14532; // Non-default port to avoid conflicts

Process? _rigctldProcess;

Future<void> _startRigctld() async {
  _rigctldProcess = await Process.start(
    'rigctld',
    ['-m', '1', '-t', '$_rigctldPort'],
  );
  // Wait for rigctld to be ready by polling the port
  for (var i = 0; i < 20; i++) {
    try {
      final socket = await Socket.connect('127.0.0.1', _rigctldPort,
          timeout: const Duration(milliseconds: 200));
      await socket.close();
      return;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('rigctld did not start within 2 seconds');
}

void _stopRigctld() {
  _rigctldProcess?.kill();
  _rigctldProcess = null;
}

void main() {
  late RigctldClient client;

  setUpAll(() async {
    await _startRigctld();
  });

  tearDownAll(() {
    _stopRigctld();
  });

  setUp(() async {
    client = RigctldClient(host: '127.0.0.1', port: _rigctldPort);
    await client.connect();
  });

  tearDown(() async {
    await client.disconnect();
  });

  test('getFrequency returns a value', () async {
    final freq = await client.getFrequency();
    expect(freq, isA<int>());
    expect(freq, greaterThanOrEqualTo(0));
  });

  test('setFrequency / getFrequency round-trip', () async {
    await client.setFrequency(14074000);
    final freq = await client.getFrequency();
    expect(freq, equals(14074000));
  });

  test('getMode returns mode and passband', () async {
    final result = await client.getMode();
    expect(result.mode, isA<String>());
    expect(result.mode, isNotEmpty);
    expect(result.passband, isA<int>());
  });

  test('setMode / getMode round-trip', () async {
    await client.setMode('USB');
    var result = await client.getMode();
    expect(result.mode, equals('USB'));

    await client.setMode('CW');
    result = await client.getMode();
    expect(result.mode, equals('CW'));

    await client.setMode('LSB');
    result = await client.getMode();
    expect(result.mode, equals('LSB'));
  });

  test('setPtt / getPtt round-trip', () async {
    await client.setPtt(true);
    var ptt = await client.getPtt();
    expect(ptt, isTrue);

    await client.setPtt(false);
    ptt = await client.getPtt();
    expect(ptt, isFalse);
  });

  test('setFrequency then setMode preserves both', () async {
    await client.setFrequency(7030000);
    await client.setMode('CW');

    final freq = await client.getFrequency();
    final mode = await client.getMode();
    expect(freq, equals(7030000));
    expect(mode.mode, equals('CW'));
  });

  test('multiple frequency changes are tracked', () async {
    final frequencies = [3573000, 14074000, 21260000, 28480000];
    for (final f in frequencies) {
      await client.setFrequency(f);
      final result = await client.getFrequency();
      expect(result, equals(f));
    }
  });

  test('getVfo returns a VFO name', () async {
    final vfo = await client.getVfo();
    expect(vfo, isA<String>());
    expect(vfo, isNotEmpty);
  });

  test('getRigInfo returns info string', () async {
    final info = await client.getRigInfo();
    expect(info, isA<String>());
  });
}
