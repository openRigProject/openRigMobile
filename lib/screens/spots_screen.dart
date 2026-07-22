import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openrig_core/openrig_core.dart';
import 'package:path_provider/path_provider.dart';

import '../connection_state.dart';
import 'log_screen.dart';

// -- Mode derivation helpers --

const _digitalKeywords = ['FT8', 'FT4', 'JS8', 'RTTY', 'PSK', 'DIGITAL', 'MFSK', 'JT65', 'JT9', 'WSPR'];
const _cwKeywords = ['CW', 'MORSE'];
const _ssbKeywords = ['SSB', 'USB', 'LSB', 'PHONE', 'AM', 'FM'];

String _modeCategory(String comment) {
  final upper = comment.toUpperCase();
  for (final kw in _digitalKeywords) {
    if (upper.contains(kw)) return 'Digital';
  }
  for (final kw in _cwKeywords) {
    if (upper.contains(kw)) return 'CW';
  }
  for (final kw in _ssbKeywords) {
    if (upper.contains(kw)) return 'SSB';
  }
  return '';
}

// -- Sort --

enum _SortColumn { frequency, dxCall, spotter, time }

enum _SpotSource { cluster, pota, sota }

class SpotsScreen extends StatefulWidget {
  final AppConnectionState appState;
  final void Function(QsoPreFill)? onLogQso;

  const SpotsScreen({super.key, required this.appState, this.onLogQso});

  @override
  State<SpotsScreen> createState() => _SpotsScreenState();
}

class _SpotsScreenState extends State<SpotsScreen> {
  DxClusterClient? _client;
  StreamSubscription<DxSpot>? _spotSub;
  var _spots = <DxSpot>[];
  Timer? _expiryTimer;
  bool _connected = false;
  String? _error;

  // POTA / SOTA
  _SpotSource _source = _SpotSource.cluster;
  List<PotaSpot> _potaSpots = [];
  List<SotaSpot> _sotaSpots = [];
  PotaClient? _potaClient;
  SotaClient? _sotaClient;
  Timer? _potaSotaTimer;
  bool _potaLoading = false;
  bool _sotaLoading = false;

  String _clusterHost = 'dxc.ve7cc.net';
  int _clusterPort = 23;
  String _callsign = 'N0CALL';

  // Filters
  String _bandFilter = 'All';
  String _modeFilter = 'All';
  bool _neededOnly = false;
  bool _newBandOnly = false;

  // Sort
  _SortColumn _sortColumn = _SortColumn.time;
  bool _sortAscending = false; // newest first by default

  // Dupe checking
  List<QsoRecord> _log = [];
  DuplicateChecker? _dupeChecker;

  static const _bands = [
    'All', '160m', '80m', '40m', '30m', '20m', '17m', '15m', '12m', '10m', '6m', '2m',
  ];
  static const _modes = ['All', 'CW', 'SSB', 'Digital'];

  @override
  void initState() {
    super.initState();
    final s = widget.appState.settings;
    if (s != null) {
      _clusterHost = s.clusterHost;
      _clusterPort = s.clusterPort;
      if (s.callsign.isNotEmpty) _callsign = s.callsign;
    }
    final device = widget.appState.device;
    if (device != null && device.callsign.isNotEmpty) {
      _callsign = device.callsign;
    }
    _loadLog();
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _spots.isNotEmpty) {
        setState(() {
          _spots = expireSpots(_spots, const Duration(minutes: 30));
        });
      }
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _potaSotaTimer?.cancel();
    _potaClient?.dispose();
    _sotaClient?.dispose();
    _disconnect();
    super.dispose();
  }

  Future<void> _loadLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/openrig_log.adi');
      if (await file.exists()) {
        final content = await file.readAsString();
        final records = AdifLog.parse(content);
        if (mounted) {
          setState(() {
            _log = records;
            _dupeChecker = DuplicateChecker(records);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _dupeChecker = DuplicateChecker([]);
          });
        }
      }
    } catch (_) {
      // Log loading is best-effort
    }
  }

  bool get _hasFilters =>
      _bandFilter != 'All' || _modeFilter != 'All' || _neededOnly || _newBandOnly;

  List<DxSpot> get _filteredSpots {
    final filter = ClusterFilter(
      bands: _bandFilter != 'All' ? [_bandFilter] : [],
      modes: _modeFilter != 'All' ? [_modeFilter] : [],
      neededOnly: _neededOnly,
      newBandOnly: _newBandOnly,
      dupeChecker: _dupeChecker,
    );
    var list = _spots.where((s) => filter.passes(s)).toList();

    list.sort((a, b) {
      int cmp;
      switch (_sortColumn) {
        case _SortColumn.frequency:
          cmp = a.frequencyKhz.compareTo(b.frequencyKhz);
        case _SortColumn.dxCall:
          cmp = a.dxCall.compareTo(b.dxCall);
        case _SortColumn.spotter:
          cmp = a.spotter.compareTo(b.spotter);
        case _SortColumn.time:
          cmp = a.time.compareTo(b.time);
      }
      return _sortAscending ? cmp : -cmp;
    });

    return list;
  }

  void _toggleSort(_SortColumn col) {
    setState(() {
      if (_sortColumn == col) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = col;
        _sortAscending = col != _SortColumn.time;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _bandFilter = 'All';
      _modeFilter = 'All';
      _neededOnly = false;
      _newBandOnly = false;
    });
  }

  Future<void> _connect() async {
    await _disconnect();
    _client = DxClusterClient(
      host: _clusterHost,
      port: _clusterPort,
      callsign: _callsign,
    );
    try {
      await _client!.connect();
      _spotSub = _client!.spots.listen((spot) {
        if (mounted) {
          setState(() {
            _spots = mergeSpot(_spots, spot);
          });
        }
      });
      setState(() {
        _connected = true;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _connected = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    await _spotSub?.cancel();
    _spotSub = null;
    await _client?.disconnect();
    _client = null;
    if (mounted) setState(() => _connected = false);
  }

  Future<void> _fetchPota() async {
    _potaClient ??= PotaClient();
    setState(() => _potaLoading = true);
    try {
      final spots = await _potaClient!.fetchActivators();
      if (mounted) setState(() { _potaSpots = spots; _potaLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _potaLoading = false);
    }
  }

  Future<void> _fetchSota() async {
    _sotaClient ??= SotaClient();
    setState(() => _sotaLoading = true);
    try {
      final spots = await _sotaClient!.fetchSpots();
      if (mounted) setState(() { _sotaSpots = spots; _sotaLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _sotaLoading = false);
    }
  }

  void _startPotaSotaTimer() {
    _potaSotaTimer?.cancel();
    _potaSotaTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_source == _SpotSource.pota) _fetchPota();
      if (_source == _SpotSource.sota) _fetchSota();
    });
  }

  void _onSourceChanged(_SpotSource source) {
    setState(() => _source = source);
    if (source == _SpotSource.pota) {
      _fetchPota();
      _startPotaSotaTimer();
    } else if (source == _SpotSource.sota) {
      _fetchSota();
      _startPotaSotaTimer();
    } else {
      _potaSotaTimer?.cancel();
      _potaSotaTimer = null;
    }
  }

  void _showPotaSpotDetail(PotaSpot spot) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(spot.activator, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('${spot.reference} — ${spot.parkName}'),
            const SizedBox(height: 4),
            Text('${spot.frequencyKhz.toStringAsFixed(1)} kHz  ${spot.mode}'),
            if (spot.comment.isNotEmpty)
              Text(spot.comment, style: const TextStyle(fontStyle: FontStyle.italic)),
            Text('de ${spot.spotter}'),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: widget.onLogQso != null ? () {
                Navigator.of(ctx).pop();
                widget.onLogQso!(QsoPreFill(
                  callsign: spot.activator,
                  freqMhz: spot.frequencyMhz,
                  mode: spot.mode.isNotEmpty ? spot.mode : null,
                  timeOn: DateTime.now().toUtc(),
                  potaRef: spot.reference,
                ));
              } : null,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.menu_book, size: 18),
                SizedBox(width: 6),
                Text('Log QSO'),
              ]),
            ),
            SizedBox(height: MediaQuery.of(ctx).viewPadding.bottom),
          ],
        ),
      ),
    );
  }

  void _showSotaSpotDetail(SotaSpot spot) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(spot.activatorCallsign, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('${spot.summitCode} — ${spot.summitName}'),
            const SizedBox(height: 4),
            Text('${spot.frequencyKhz.toStringAsFixed(1)} kHz  ${spot.mode}'),
            if (spot.comments.isNotEmpty)
              Text(spot.comments, style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: widget.onLogQso != null ? () {
                Navigator.of(ctx).pop();
                widget.onLogQso!(QsoPreFill(
                  callsign: spot.activatorCallsign,
                  freqMhz: spot.frequencyMhz,
                  mode: spot.mode.isNotEmpty ? spot.mode : null,
                  timeOn: DateTime.now().toUtc(),
                  sotaRef: spot.summitCode,
                ));
              } : null,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.menu_book, size: 18),
                SizedBox(width: 6),
                Text('Log QSO'),
              ]),
            ),
            SizedBox(height: MediaQuery.of(ctx).viewPadding.bottom),
          ],
        ),
      ),
    );
  }

  Future<void> _tuneToSpot(DxSpot spot) async {
    final rig = widget.appState.rigctld;
    if (rig == null || !rig.isConnected) return;
    try {
      await rig.setFrequency(khzToHz(spot.frequencyKhz));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tuned to ${spot.frequencyKhz.toStringAsFixed(1)} kHz')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to tune: $e')),
        );
      }
    }
  }

  /// Build a dupe status widget for a spot row.
  Widget? _spotDupeIndicator(DxSpot spot) {
    final checker = _dupeChecker;
    if (checker == null) return null;

    final call = spot.dxCall;
    final band = bandFromKhz(spot.frequencyKhz)?.name ?? '';
    final mode = _modeCategory(spot.comment);

    if (band.isNotEmpty && mode.isNotEmpty && checker.isWorkedOnBandMode(call, band, mode)) {
      return Icon(Icons.check_circle, size: 14, color: Colors.green.shade400);
    }
    if (checker.isWorked(call)) {
      return const Icon(Icons.circle, size: 8, color: Colors.grey);
    }
    return null;
  }

  void _showSpotDetail(DxSpot spot) {
    final colorScheme = Theme.of(context).colorScheme;
    final entity = lookupDxcc(spot.dxCall);
    final band = bandFromKhz(spot.frequencyKhz)?.name ?? '';
    final mode = _modeCategory(spot.comment);
    final rigConnected = widget.appState.rigctld?.isConnected ?? false;

    // Count previous QSOs with same DXCC entity
    final int dxccCount;
    if (entity.isNotEmpty) {
      dxccCount = LogSearch.filter(_log, dxcc: entity).length;
    } else {
      dxccCount = 0;
    }

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Callsign + entity
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  spot.dxCall,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Text(
                  entity,
                  style: TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Info rows
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _DetailChip(
                  icon: Icons.radio,
                  label: '${spot.frequencyKhz.toStringAsFixed(1)} kHz',
                ),
                if (band.isNotEmpty)
                  _DetailChip(icon: Icons.straighten, label: band),
                if (mode.isNotEmpty)
                  _DetailChip(icon: Icons.tune, label: mode),
                _DetailChip(
                  icon: Icons.access_time,
                  label: _formatTime(spot.time),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // DXCC QSO count
            if (entity.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$dxccCount previous QSO${dxccCount == 1 ? '' : 's'} with $entity',
                  style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
                ),
              ),

            // Spotter + comment
            Text(
              'de ${spot.spotter}',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (spot.comment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                spot.comment,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 20),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: rigConnected
                        ? () {
                            Navigator.of(ctx).pop();
                            _tuneToSpot(spot);
                          }
                        : null,
                    icon: const Icon(Icons.settings_remote),
                    label: const Text('Tune'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: widget.onLogQso != null
                        ? () {
                            Navigator.of(ctx).pop();
                            final freqMhz = spot.frequencyKhz / 1000.0;
                            final modeStr = mode.isNotEmpty ? mode : null;
                            final rstDefault = modeStr == 'CW' ? '599' : '59';
                            widget.onLogQso!(QsoPreFill(
                              callsign: spot.dxCall,
                              freqMhz: freqMhz,
                              mode: modeStr,
                              timeOn: DateTime.now().toUtc(),
                              rstSent: rstDefault,
                              rstRcvd: rstDefault,
                            ));
                          }
                        : null,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book, size: 18),
                        SizedBox(width: 6),
                        Text('Log QSO'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: spot.dxCall));
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${spot.dxCall} copied to clipboard')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ],
            ),
            // Bottom padding for devices with home indicator
            SizedBox(height: MediaQuery.of(ctx).viewPadding.bottom),
          ],
        ),
      ),
    );
  }

  void _showSettings() {
    final hostCtrl = TextEditingController(text: _clusterHost);
    final portCtrl = TextEditingController(text: _clusterPort.toString());
    final callCtrl = TextEditingController(text: _callsign);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DX Cluster Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(labelText: 'Host'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portCtrl,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: callCtrl,
              decoration: const InputDecoration(labelText: 'Your callsign'),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              final host = hostCtrl.text.trim();
              final port = int.tryParse(portCtrl.text.trim()) ?? 23;
              final call = callCtrl.text.trim().toUpperCase();
              setState(() {
                _clusterHost = host;
                _clusterPort = port;
                _callsign = call;
              });
              final s = widget.appState.settings;
              s?.setCluster(host, port);
              if (call.isNotEmpty) s?.setCallsign(call);
              Navigator.of(ctx).pop();
              _connect();
            },
            child: const Text('CONNECT'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildSourceSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<_SpotSource>(
        segments: const [
          ButtonSegment(value: _SpotSource.cluster, label: Text('DX Cluster')),
          ButtonSegment(value: _SpotSource.pota, label: Text('POTA')),
          ButtonSegment(value: _SpotSource.sota, label: Text('SOTA')),
        ],
        selected: {_source},
        onSelectionChanged: (selected) => _onSourceChanged(selected.first),
      ),
    );
  }

  Widget _buildPotaSotaBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_source == _SpotSource.pota) {
      if (_potaLoading && _potaSpots.isEmpty) {
        return const Expanded(child: Center(child: CircularProgressIndicator()));
      }
      if (_potaSpots.isEmpty) {
        return Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.park, size: 48, color: colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                const Text('No POTA spots'),
              ],
            ),
          ),
        );
      }
      return Expanded(
        child: ListView.separated(
          itemCount: _potaSpots.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final spot = _potaSpots[index];
            return ListTile(
              title: Text(spot.activator, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${spot.reference} ${spot.parkName}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${spot.frequencyKhz.toStringAsFixed(1)} kHz', style: const TextStyle(fontFamily: 'monospace')),
                  Text(spot.mode, style: const TextStyle(fontSize: 12)),
                ],
              ),
              onTap: () => _showPotaSpotDetail(spot),
            );
          },
        ),
      );
    }

    // SOTA
    if (_sotaLoading && _sotaSpots.isEmpty) {
      return const Expanded(child: Center(child: CircularProgressIndicator()));
    }
    if (_sotaSpots.isEmpty) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terrain, size: 48, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              const Text('No SOTA spots'),
            ],
          ),
        ),
      );
    }
    return Expanded(
      child: ListView.separated(
        itemCount: _sotaSpots.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final spot = _sotaSpots[index];
          return ListTile(
            title: Text(spot.activatorCallsign, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${spot.summitCode} ${spot.summitName}'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${spot.frequencyKhz.toStringAsFixed(1)} kHz', style: const TextStyle(fontFamily: 'monospace')),
                Text(spot.mode, style: const TextStyle(fontSize: 12)),
              ],
            ),
            onTap: () => _showSotaSpotDetail(spot),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_source == _SpotSource.cluster && !_connected && _spots.isEmpty) {
      return Column(
        children: [
          _buildSourceSelector(),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.radar, size: 64, color: colorScheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  const Text('DX Cluster not connected'),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: colorScheme.error, fontSize: 12)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _showSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Configure & Connect'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final filtered = _filteredSpots;

    return Column(
      children: [
        _buildSourceSelector(),

        if (_source == _SpotSource.cluster) ...[
          // Connection status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(
                  _connected ? Icons.cloud_done : Icons.cloud_off,
                  size: 16,
                  color: _connected ? Colors.green : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _connected
                        ? '$_clusterHost:$_clusterPort'
                        : 'Disconnected',
                    style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings, size: 18),
                  onPressed: _showSettings,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          // Filter bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: colorScheme.surfaceContainerHigh,
            child: Row(
              children: [
                Flexible(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _bandFilter,
                      isDense: true,
                      style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
                      items: [
                        for (final b in _bands)
                          DropdownMenuItem(value: b, child: Text(b)),
                      ],
                      onChanged: (v) => setState(() => _bandFilter = v ?? 'All'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _modeFilter,
                      isDense: true,
                      style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
                      items: [
                        for (final m in _modes)
                          DropdownMenuItem(value: m, child: Text(m)),
                      ],
                      onChanged: (v) => setState(() => _modeFilter = v ?? 'All'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Needed'),
                  selected: _neededOnly,
                  onSelected: (v) => setState(() {
                    _neededOnly = v;
                    if (v) _newBandOnly = false;
                  }),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelStyle: const TextStyle(fontSize: 11),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('New Band'),
                  selected: _newBandOnly,
                  onSelected: (v) => setState(() {
                    _newBandOnly = v;
                    if (v) _neededOnly = false;
                  }),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelStyle: const TextStyle(fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${filtered.length} spot${filtered.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
                if (_hasFilters) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: _clearFilters,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.filter_alt_off, size: 18, color: colorScheme.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Column headers
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                _ColumnHeader(label: 'Freq', col: _SortColumn.frequency, current: _sortColumn, ascending: _sortAscending, onTap: _toggleSort),
                const SizedBox(width: 12),
                Expanded(child: _ColumnHeader(label: 'DX', col: _SortColumn.dxCall, current: _sortColumn, ascending: _sortAscending, onTap: _toggleSort)),
                Expanded(child: _ColumnHeader(label: 'Spotter', col: _SortColumn.spotter, current: _sortColumn, ascending: _sortAscending, onTap: _toggleSort)),
                _ColumnHeader(label: 'Time', col: _SortColumn.time, current: _sortColumn, ascending: _sortAscending, onTap: _toggleSort),
              ],
            ),
          ),

          // Spot list or empty state
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.filter_alt, size: 48, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 12),
                        const Text('No spots match your filters'),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _clearFilters,
                          icon: const Icon(Icons.filter_alt_off),
                          label: const Text('Clear Filters'),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final spot = filtered[index];
                      final dupeIcon = _spotDupeIndicator(spot);
                      return ListTile(
                        dense: true,
                        leading: Text(
                          spot.frequencyKhz.toStringAsFixed(1),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: colorScheme.primary,
                            fontFamily: 'monospace',
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(spot.dxCall, style: const TextStyle(fontWeight: FontWeight.bold)),
                            if (dupeIcon != null) ...[
                              const SizedBox(width: 6),
                              dupeIcon,
                            ],
                          ],
                        ),
                        subtitle: Text('de ${spot.spotter}  ${spot.comment}'),
                        trailing: Text(
                          _formatTime(spot.time),
                          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                        onTap: () => _showSpotDetail(spot),
                        onLongPress: () => _tuneToSpot(spot),
                      );
                    },
                  ),
          ),
        ] else ...[
          _buildPotaSotaBody(context),
        ],
      ],
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  final String label;
  final _SortColumn col;
  final _SortColumn current;
  final bool ascending;
  final ValueChanged<_SortColumn> onTap;

  const _ColumnHeader({
    required this.label,
    required this.col,
    required this.current,
    required this.ascending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = current == col;
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onTap(col),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
            ),
            if (isActive)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(
                  ascending ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 12,
                  color: colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DetailChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 13, color: colorScheme.onSurface)),
        ],
      ),
    );
  }
}
