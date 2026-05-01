import 'dart:io';
import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import 'package:path_provider/path_provider.dart';

import '../connection_state.dart';

/// Pre-fill data for the New QSO dialog, e.g. from a DX spot.
class QsoPreFill {
  final String? callsign;
  final double? freqMhz;
  final String? mode;
  final DateTime? timeOn;
  final String? rstSent;
  final String? rstRcvd;

  const QsoPreFill({
    this.callsign,
    this.freqMhz,
    this.mode,
    this.timeOn,
    this.rstSent,
    this.rstRcvd,
  });
}

class LogScreen extends StatefulWidget {
  final AppConnectionState appState;
  final String? logPath; // Injectable for testing

  const LogScreen({super.key, required this.appState, this.logPath});

  @override
  State<LogScreen> createState() => LogScreenState();
}

class LogScreenState extends State<LogScreen> {
  List<QsoRecord> _qsos = [];
  DuplicateChecker? _dupeChecker;
  String? _logPath;
  bool _loading = true;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  // Stats (computed from full log)
  int _dxccCount = 0;
  int _wasCount = 0;
  Map<String, int> _bandCounts = {};

  @override
  void initState() {
    super.initState();
    _loadLog();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Open the New QSO dialog with optional pre-fill data.
  void openNewQsoDialog({QsoPreFill? preFill}) {
    _showNewQsoDialog(preFill: preFill);
  }

  Future<String> _getLogPath() async {
    if (_logPath != null) return _logPath!;
    if (widget.logPath != null) {
      _logPath = widget.logPath;
      return _logPath!;
    }
    final dir = await getApplicationDocumentsDirectory();
    _logPath = '${dir.path}/openrig_log.adi';
    return _logPath!;
  }

  Future<void> _loadLog() async {
    final path = await _getLogPath();
    final file = File(path);
    if (await file.exists()) {
      final content = await file.readAsString();
      final records = AdifLog.parse(content);
      setState(() {
        _qsos = records.reversed.toList();
        _dupeChecker = DuplicateChecker(records);
        _dxccCount = countDxcc(records);
        _wasCount = countWas(records);
        _bandCounts = qsosByBand(records);
        _loading = false;
      });
    } else {
      setState(() {
        _dupeChecker = DuplicateChecker([]);
        _dxccCount = 0;
        _wasCount = 0;
        _bandCounts = {};
        _loading = false;
      });
    }
  }

  void _uploadToQrz(QsoRecord record) {
    final key = widget.appState.settings?.qrzApiKey ?? '';
    if (key.isEmpty) return;
    final client = QrzLogbookClient(apiKey: key);
    client.insertQso(record).then((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logged to QRZ \u2713')),
        );
      }
    }).catchError((Object e) {
      if (mounted) {
        final reason = e is QrzException ? e.message : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ upload failed: $reason')),
        );
      }
    }).whenComplete(() => client.dispose());
  }

  List<QsoRecord> get _displayedQsos {
    if (_searchQuery.isEmpty) return _qsos;
    return LogSearch.filter(_qsos, callsign: _searchQuery);
  }

  void _showNewQsoDialog({QsoPreFill? preFill}) {
    // Default RST based on mode
    final defaultRst = (preFill?.mode?.toUpperCase() == 'CW') ? '599' : '59';
    final callCtrl = TextEditingController(text: preFill?.callsign ?? '');
    final freqCtrl = TextEditingController(
      text: preFill?.freqMhz != null
          ? preFill!.freqMhz!.toStringAsFixed(6)
          : '',
    );
    final modeCtrl = TextEditingController(
      text: preFill?.mode ?? 'SSB',
    );
    final rstSentCtrl = TextEditingController(
      text: preFill?.rstSent ?? defaultRst,
    );
    final rstRcvdCtrl = TextEditingController(
      text: preFill?.rstRcvd ?? defaultRst,
    );

    // Override frequency and mode from rig if connected (more accurate)
    final rig = widget.appState.rigctld;
    if (rig != null && rig.isConnected) {
      rig.getFrequency().then((hz) {
        final mhz = hz / 1000000.0;
        freqCtrl.text = mhz.toStringAsFixed(6);
      }).catchError((_) {});
      rig.getMode().then((result) {
        modeCtrl.text = result.mode;
      }).catchError((_) {});
    }

    showDialog(
      context: context,
      builder: (ctx) => _NewQsoDialog(
        callCtrl: callCtrl,
        freqCtrl: freqCtrl,
        modeCtrl: modeCtrl,
        rstSentCtrl: rstSentCtrl,
        rstRcvdCtrl: rstRcvdCtrl,
        dupeChecker: _dupeChecker,
        preFill: preFill,
        onSave: (record) async {
          final path = await _getLogPath();
          await AdifLog.appendRecord(path, record);
          _dupeChecker?.addQso(record);
          _loadLog();
          _uploadToQrz(record);
        },
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final displayed = _displayedQsos;

    return Scaffold(
      body: _qsos.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book, size: 64, color: colorScheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  const Text('No QSOs logged yet'),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to log your first contact',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Stats card
                _LogStatsCard(
                  qsoCount: _qsos.length,
                  dxccCount: _dxccCount,
                  wasCount: _wasCount,
                  bandCounts: _bandCounts,
                ),
                // Search bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search callsign...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${displayed.length} QSO${displayed.length == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: displayed.isEmpty
                      ? Center(
                          child: Text(
                            'No matching QSOs',
                            style: TextStyle(color: colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          itemCount: displayed.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final qso = displayed[index];
                            return ListTile(
                              title: Text(
                                qso.call,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              subtitle: Text(
                                '${qso.freqMhz.toStringAsFixed(3)} MHz  ${qso.mode}'
                                '${qso.rstSent != null ? '  RST ${qso.rstSent}' : ''}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: Text(
                                _formatDateTime(qso.timeOn),
                                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewQsoDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// -- Stats card --

class _LogStatsCard extends StatelessWidget {
  final int qsoCount;
  final int dxccCount;
  final int wasCount;
  final Map<String, int> bandCounts;

  const _LogStatsCard({
    required this.qsoCount,
    required this.dxccCount,
    required this.wasCount,
    required this.bandCounts,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(
        '$qsoCount QSOs  \u2022  DXCC: $dxccCount  \u2022  WAS: $wasCount',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      children: [
        if (bandCounts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _BandChart(bandCounts: bandCounts, colorScheme: colorScheme),
          ),
      ],
    );
  }
}

class _BandChart extends StatelessWidget {
  final Map<String, int> bandCounts;
  final ColorScheme colorScheme;

  const _BandChart({required this.bandCounts, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final sorted = bandCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top5 = sorted.take(5).toList();
    if (top5.isEmpty) return const SizedBox.shrink();
    final maxCount = top5.first.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in top5)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    entry.key.isEmpty ? '?' : entry.key,
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fraction = maxCount > 0 ? entry.value / maxCount : 0.0;
                      return Container(
                        height: 14,
                        width: constraints.maxWidth * fraction,
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withAlpha(140),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 32,
                  child: Text(
                    '${entry.value}',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// -- New QSO dialog with dupe checking --

class _NewQsoDialog extends StatefulWidget {
  final TextEditingController callCtrl;
  final TextEditingController freqCtrl;
  final TextEditingController modeCtrl;
  final TextEditingController rstSentCtrl;
  final TextEditingController rstRcvdCtrl;
  final DuplicateChecker? dupeChecker;
  final QsoPreFill? preFill;
  final Future<void> Function(QsoRecord) onSave;

  const _NewQsoDialog({
    required this.callCtrl,
    required this.freqCtrl,
    required this.modeCtrl,
    required this.rstSentCtrl,
    required this.rstRcvdCtrl,
    required this.dupeChecker,
    required this.preFill,
    required this.onSave,
  });

  @override
  State<_NewQsoDialog> createState() => _NewQsoDialogState();
}

class _NewQsoDialogState extends State<_NewQsoDialog> {
  final _mySotaCtl = TextEditingController();
  final _sotaCtl = TextEditingController();
  final _myPotaCtl = TextEditingController();
  final _potaCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.callCtrl.addListener(_onCallChanged);
    widget.freqCtrl.addListener(_onCallChanged);
    widget.modeCtrl.addListener(_onCallChanged);
  }

  @override
  void dispose() {
    widget.callCtrl.removeListener(_onCallChanged);
    widget.freqCtrl.removeListener(_onCallChanged);
    widget.modeCtrl.removeListener(_onCallChanged);
    _mySotaCtl.dispose();
    _sotaCtl.dispose();
    _myPotaCtl.dispose();
    _potaCtl.dispose();
    super.dispose();
  }

  void _onCallChanged() => setState(() {});

  Widget? _buildDupeIndicator() {
    final checker = widget.dupeChecker;
    if (checker == null) return null;

    final call = widget.callCtrl.text.trim().toUpperCase();
    if (call.isEmpty) return null;

    final freq = double.tryParse(widget.freqCtrl.text.trim());
    final band = freq != null ? (bandFromMhz(freq)?.name ?? '') : '';
    final mode = widget.modeCtrl.text.trim().toUpperCase();

    if (band.isNotEmpty && mode.isNotEmpty && checker.isWorkedOnBandMode(call, band, mode)) {
      return Chip(
        label: const Text('DUPE'),
        backgroundColor: Colors.red.withAlpha(40),
        side: BorderSide(color: Colors.red.withAlpha(100)),
        labelStyle: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      );
    }
    if (band.isNotEmpty && checker.isWorkedOnBand(call, band)) {
      return Chip(
        label: const Text('New mode'),
        backgroundColor: Colors.amber.withAlpha(40),
        side: BorderSide(color: Colors.amber.withAlpha(100)),
        labelStyle: TextStyle(color: Colors.amber.shade800, fontWeight: FontWeight.bold, fontSize: 12),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      );
    }
    if (checker.isWorked(call)) {
      return Chip(
        label: const Text('Worked'),
        backgroundColor: Colors.grey.withAlpha(40),
        side: BorderSide(color: Colors.grey.withAlpha(100)),
        labelStyle: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final dupeIndicator = _buildDupeIndicator();

    return AlertDialog(
      title: const Text('New QSO'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: widget.callCtrl,
              decoration: const InputDecoration(labelText: 'Callsign'),
              textCapitalization: TextCapitalization.characters,
              autofocus: true,
            ),
            if (dupeIndicator != null) ...[
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: dupeIndicator),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: widget.freqCtrl,
              decoration: const InputDecoration(labelText: 'Frequency (MHz)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.modeCtrl,
              decoration: const InputDecoration(labelText: 'Mode'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.rstSentCtrl,
              decoration: const InputDecoration(labelText: 'RST Sent'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.rstRcvdCtrl,
              decoration: const InputDecoration(labelText: 'RST Received'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              title: const Text('POTA / SOTA', style: TextStyle(fontSize: 14)),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              children: [
                TextField(
                  controller: _mySotaCtl,
                  decoration: const InputDecoration(
                    labelText: 'My Summit',
                    hintText: 'e.g. W7W/KG-001',
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _sotaCtl,
                  decoration: const InputDecoration(
                    labelText: 'Their Summit',
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _myPotaCtl,
                  decoration: const InputDecoration(
                    labelText: 'My Park',
                    hintText: 'e.g. K-0001',
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _potaCtl,
                  decoration: const InputDecoration(
                    labelText: 'Their Park',
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: () async {
            final call = normalizeCallsign(widget.callCtrl.text);
            final freqStr = widget.freqCtrl.text.trim();
            final mode = widget.modeCtrl.text.trim().toUpperCase();
            if (call.isEmpty || freqStr.isEmpty || mode.isEmpty) return;

            if (!isValidCallsign(call)) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid callsign')),
                );
              }
              return;
            }

            final freq = double.tryParse(freqStr);
            if (freq == null) return;

            final mySota = _mySotaCtl.text.trim();
            final sota = _sotaCtl.text.trim();
            final myPota = _myPotaCtl.text.trim();
            final pota = _potaCtl.text.trim();

            final record = QsoRecord(
              call: call,
              band: bandFromMhz(freq)?.name ?? '',
              mode: mode,
              freqMhz: freq,
              timeOn: DateTime.now().toUtc(),
              rstSent: widget.rstSentCtrl.text.trim(),
              rstRcvd: widget.rstRcvdCtrl.text.trim(),
              mySotaRef: mySota.isEmpty ? null : mySota,
              sotaRef: sota.isEmpty ? null : sota,
              myPotaRef: myPota.isEmpty ? null : myPota,
              potaRef: pota.isEmpty ? null : pota,
            );

            await widget.onSave(record);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}
