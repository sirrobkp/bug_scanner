import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:async';
import 'dart:math';

// NOTE ON WHAT THIS SCREEN CAN ACTUALLY MEASURE ON A PHONE:
// - EMF / magnetic field: phones have a real magnetometer (used for the
//   compass). We read it live and track deviation from a rolling baseline —
//   ambient field varies a lot by location (near rebar, wiring, appliances),
//   so "anomaly vs. your own baseline" is the honest signal, not an
//   absolute threshold. This detects magnetic/electrical anomalies; it is
//   not a certified "bug detector," the same way commercial EMF meters
//   aren't — a fridge motor or laptop charger will also spike it.
// - RF: a phone has no general-purpose RF spectrum receiver, so it cannot
//   scan "RF" in the abstract. What it CAN genuinely do is Bluetooth Low
//   Energy scanning — real nearby BLE devices with real measured RSSI. We
//   use that for the "signal strength" and radar-blip data, and flag
//   devices that are unnamed, strong-signal, and persistently present
//   (the same category of heuristic Apple/Google's own "unknown tracker"
//   alerts use) as worth a manual look.
// - WiFi shows real "connected" status, not a spectrum scan.
// - Zigbee and Z-Wave use radios phones simply don't have — there is no
//   API and no hardware, on any phone, for an app to detect them. We keep
//   them visible in the protocol list but mark them as unsupported by the
//   hardware rather than pretending to scan for them.
// - BLE gives no bearing/direction, only approximate proximity from RSSI.
//   Radar blip *angle* is therefore arbitrary (stable per-device, not a
//   real compass bearing) — only the *radial distance* loosely reflects
//   measured signal strength. Distance-in-meters is a rough RSSI-based
//   estimate (standard log-distance path-loss formula) that can easily be
//   off by several meters indoors — walls, orientation, and multipath all
//   affect it.

// ── Radar Canvas ─────────────────────────────────────────────────
/// One real detected BLE device, reduced to what the radar can honestly
/// display: a stable ID (for a consistent on-screen position), a normalized
/// proximity distance (0 = strong/near, 1 = weak/far — derived from real
/// RSSI), and whether our heuristic flags it as worth a closer look.
class RadarDevice {
  final String id;
  final double distance01;
  final bool suspicious;

  const RadarDevice({
    required this.id,
    required this.distance01,
    required this.suspicious,
  });
}

class RadarCanvas extends StatefulWidget {
  final double size;
  final List<RadarDevice> devices;

  const RadarCanvas({super.key, required this.size, this.devices = const []});

  @override
  State<RadarCanvas> createState() => _RadarCanvasState();
}

class _RadarCanvasState extends State<RadarCanvas>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _angle = 0;
  List<_Blip> _blips = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 257),
    )..addListener(() {
        setState(() {
          _angle = (_angle + 1.4) % 360;
        });
      });

    _rebuildBlips();
    _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RadarCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDevices(oldWidget.devices, widget.devices)) {
      _rebuildBlips();
    }
  }

  bool _sameDevices(List<RadarDevice> a, List<RadarDevice> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          (a[i].distance01 - b[i].distance01).abs() > 0.02 ||
          a[i].suspicious != b[i].suspicious) {
        return false;
      }
    }
    return true;
  }

  void _rebuildBlips() {
    // Real BLE scans carry no bearing — only proximity. Each device gets a
    // stable angle derived from its own ID (so it doesn't jitter around the
    // dial between refreshes); only the radial distance is a real signal.
    _blips = widget.devices.map((d) {
      final angleSeed = (d.id.hashCode.abs() % 360) * pi / 180;
      final r = (0.15 + d.distance01.clamp(0.0, 1.0) * 0.8) * (widget.size / 2 - 4);
      return _Blip(
        x: widget.size / 2 + cos(angleSeed) * r,
        y: widget.size / 2 + sin(angleSeed) * r,
        age: (d.id.hashCode.abs() % 360).toDouble(),
        r: d.suspicious ? 4.5 : 2.5,
        suspicious: d.suspicious,
      );
    }).toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(widget.size, widget.size),
      painter: RadarPainter(
        angle: _angle,
        blips: _blips,
        size: widget.size,
      ),
    );
  }
}

class _Blip {
  final double x, y, age, r;
  final bool suspicious;
  _Blip({
    required this.x,
    required this.y,
    required this.age,
    required this.r,
    this.suspicious = false,
  });
}

class RadarPainter extends CustomPainter {
  final double angle;
  final List<_Blip> blips;
  final double size;

  RadarPainter({
    required this.angle,
    required this.blips,
    required this.size,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.width / 2 - 4;
    final paint = Paint();

    // Background
    paint.color = const Color(0xFF0D0D0D);
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), radius, paint);

    // Grid rings
    paint.style = PaintingStyle.stroke;
    paint.color = const Color(0xFF00FF66).withOpacity(0.1);
    paint.strokeWidth = 1;
    for (double f = 0.25; f <= 1; f += 0.25) {
      canvas.drawCircle(Offset(cx, cy), radius * f, paint);
    }

    // Cross hairs
    paint.color = const Color(0xFF00FF66).withOpacity(0.08);
    canvas.drawLine(Offset(cx, cy - radius), Offset(cx, cy + radius), paint);
    canvas.drawLine(Offset(cx - radius, cy), Offset(cx + radius, cy), paint);

    // Diagonal lines
    for (double deg in [45, 135]) {
      final r = deg * pi / 180;
      canvas.drawLine(
        Offset(cx - cos(r) * radius, cy - sin(r) * radius),
        Offset(cx + cos(r) * radius, cy + sin(r) * radius),
        paint,
      );
    }

    // Sweep trail
    final sweepRad = angle * pi / 180;
    final trailSpan = 90 * pi / 180;
    final trailStart = sweepRad - trailSpan;

    for (int i = 0; i < 24; i++) {
      final a0 = trailStart + (i / 24) * trailSpan;
      final a1 = trailStart + ((i + 1) / 24) * trailSpan;
      final alpha = (i / 24) * 0.45;
      
      paint.color = const Color(0xFF00FF66).withOpacity(alpha);
      paint.style = PaintingStyle.fill;
      
      final path = Path();
      path.moveTo(cx, cy);
      path.arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        a0,
        a1 - a0,
        false,
      );
      path.close();
      canvas.drawPath(path, paint);
    }

    // Leading sweep line
    paint.color = const Color(0xFF00FF66);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 2;
    paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + cos(sweepRad) * radius, cy + sin(sweepRad) * radius),
      paint,
    );
    paint.maskFilter = null;

    // Blips
    for (final blip in blips) {
      final diff = ((angle - blip.age) % 360 + 360) % 360;
      if (diff < 180) {
        final fade = 1 - diff / 180;
        final blipColor = blip.suspicious ? const Color(0xFFFF2244) : const Color(0xFF00FF66);
        paint.color = blipColor.withOpacity(fade);
        paint.style = PaintingStyle.fill;
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, (blip.suspicious ? 12 : 8) * fade);
        canvas.drawCircle(
          Offset(blip.x, blip.y),
          blip.r,
          paint,
        );
        paint.maskFilter = null;
      }
    }

    // Center dot
    paint.color = const Color(0xFF00FF66);
    paint.style = PaintingStyle.fill;
    paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(Offset(cx, cy), 3, paint);
    paint.maskFilter = null;

    // Outer ring
    paint.color = const Color(0xFF00FF66).withOpacity(0.3);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 1.5;
    canvas.drawCircle(Offset(cx, cy), radius, paint);

    // Tick marks
    for (int i = 0; i < 36; i++) {
      final a = (i / 36) * 2 * pi;
      final inner = i % 9 == 0 ? radius - 10 : radius - 5;
      paint.color = const Color(0xFF00FF66).withOpacity(0.4);
      paint.strokeWidth = i % 9 == 0 ? 1.5 : 0.8;
      canvas.drawLine(
        Offset(cx + cos(a) * inner, cy + sin(a) * inner),
        Offset(cx + cos(a) * radius, cy + sin(a) * radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ── EMF Needle gauge ─────────────────────────────────────────────
class NeedleGauge extends StatelessWidget {
  final double value;

  const NeedleGauge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    // Map 0-100 to -75 to +75 degrees (150 degree sweep like original)
    final angle = -75 + (value / 100) * 150;
    final isSpike = value > 70;

    return SizedBox(
      height: 120,
      width: double.infinity,
      child: CustomPaint(
        painter: NeedleGaugePainter(angle: angle, isSpike: isSpike),
      ),
    );
  }
}

class NeedleGaugePainter extends CustomPainter {
  final double angle;
  final bool isSpike;

  NeedleGaugePainter({required this.angle, required this.isSpike});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height - 10;
    final radius = min(size.width / 2 - 20, 80.0);
    final paint = Paint();

    // ── Semi-circle arc background ──
    // Rotated 90° to the left so arc opens upward
    // Start at -165° (LOW - left side) 
    // End at -15° (HIGH - right side)
    // Total sweep = 150°
    paint.color = const Color(0xFF00FF66).withOpacity(0.1);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 6;
    paint.strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -165 * pi / 180,  // Start at -165° (LOW position - left side, rotated 90° left)
      150 * pi / 180,   // Sweep 150° to -15° (HIGH position - right side)
      false,
      paint,
    );

    // ── Arc zones ──
    // GREEN zone: LOW to MED (0 to 50%)
    paint.color = const Color(0xFF00FF66).withOpacity(0.25);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -165 * pi / 180,
      75 * pi / 180,    // 0% to 50% = -165° to -90°
      false,
      paint,
    );
    
    // YELLOW zone: MED to HIGH (50% to 75%)
    paint.color = const Color(0xFFFFB800).withOpacity(0.25);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -90 * pi / 180,
      37.5 * pi / 180,  // 50% to 75% = -90° to -52.5°
      false,
      paint,
    );
    
    // RED zone: HIGH to MAX (75% to 100%)
    paint.color = const Color(0xFFFF2244).withOpacity(0.35);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -52.5 * pi / 180,
      37.5 * pi / 180,  // 75% to 100% = -52.5° to -15°
      false,
      paint,
    );

    // ── Tick marks (9 ticks from -165° to -15°) ──
    paint.color = const Color(0xFF00FF66).withOpacity(0.4);
    paint.strokeWidth = 1.5;
    for (int i = 0; i <= 8; i++) {
      // Each tick is 18.75° apart: -165, -146.25, -127.5, -108.75, -90, -71.25, -52.5, -33.75, -15
      final a = (-165 + i * 18.75) * pi / 180;
      final r1 = radius - 8;
      final r2 = radius;
      canvas.drawLine(
        Offset(cx + cos(a) * r1, cy + sin(a) * r1),
        Offset(cx + cos(a) * r2, cy + sin(a) * r2),
        paint,
      );
    }

    // ── Needle ──
    final rad = angle * pi / 180;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rad);

    paint.color = isSpike ? const Color(0xFFFF2244) : const Color(0xFF00FF66);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 2.5;
    paint.strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(0, -radius + 8), paint);

    // Needle tip
    paint.style = PaintingStyle.fill;
    paint.maskFilter = MaskFilter.blur(
      BlurStyle.normal,
      isSpike ? 4 : 3,
    );
    final path = Path();
    path.moveTo(0, -radius + 4);
    path.lineTo(-3, -radius + 14);
    path.lineTo(3, -radius + 14);
    path.close();
    canvas.drawPath(path, paint);
    paint.maskFilter = null;

    canvas.restore();

    // ── Center cap ──
    paint.color = const Color(0xFF1A1A1A);
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 6, paint);
    paint.color = const Color(0xFF00FF66).withOpacity(0.4);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 1.5;
    canvas.drawCircle(Offset(cx, cy), 6, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _BleTrack {
  final String id;
  String? name;
  int rssi = -100;
  DateTime lastSeen = DateTime.now();
  int hitStreak = 0;

  _BleTrack({required this.id});
}
class SignalBars extends StatelessWidget {
  final int dbm;

  const SignalBars({super.key, required this.dbm});

  @override
  Widget build(BuildContext context) {
    final pct = max(0, min(1, (dbm + 100) / 60));
    final barCount = 20;
    final filledBars = (pct * barCount).round();

    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(barCount, (i) {
          final h = 4 + (i / barCount) * 20;
          final filled = i < filledBars;
          Color color;
          if (i < barCount * 0.5) {
            color = const Color(0xFF00FF66);
          } else if (i < barCount * 0.8) {
            color = const Color(0xFFFFB800);
          } else {
            color = const Color(0xFFFF2244);
          }
          return Container(
            width: 6,
            height: h,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: filled ? color : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(1),
              boxShadow: filled
                  ? [
                      BoxShadow(
                        color: color.withOpacity(0.5),
                        blurRadius: 4,
                      ),
                    ]
                  : null,
            ),
          );
        }),
      ),
    );
  }
}

// ── Main screen ──────────────────────────────────────────────────
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  // EMF — real magnetometer readings.
  double _magnitudeUt = 0; // latest |B| field magnitude, microtesla
  double _emfGauge = 15; // 0-100, mapped for the needle display only
  final List<double> _magBaselineWindow = [];
  static const int _magBaselineSize = 40; // ~ rolling ambient baseline
  StreamSubscription<MagnetometerEvent>? _magSub;

  // BLE — real nearby-device scan.
  bool _bleAvailable = true;
  bool _bleScanning = false;
  StreamSubscription<List<ScanResult>>? _bleResultsSub;
  final Map<String, _BleTrack> _bleTracks = {};
  Timer? _bleRestartTimer;

  bool _wifiConnected = false;
  int _dbm = -100;

  bool _scanning = true;
  int _threatCount = 0;
  String _scanStatus = 'SCANNING';
  double _radarSize = 240;
  late AnimationController _pulseController;

  final AudioPlayer _beepPlayer = AudioPlayer();
  DateTime? _lastBeepAt;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _checkWifi();
    _startMagnetometer();
    _startBleScanning();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _magSub?.cancel();
    _bleResultsSub?.cancel();
    _bleRestartTimer?.cancel();
    if (_bleScanning) {
      FlutterBluePlus.stopScan();
    }
    _beepPlayer.dispose();
    super.dispose();
  }

  Future<void> _checkWifi() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (mounted) setState(() => _wifiConnected = ip != null && ip.isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _wifiConnected = false);
    }
  }

  // ── Magnetometer (real EMF) ──────────────────────────────────────
  void _startMagnetometer() {
    _magSub?.cancel();
    _magSub = magnetometerEventStream().listen((event) {
      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      _magBaselineWindow.add(magnitude);
      if (_magBaselineWindow.length > _magBaselineSize) {
        _magBaselineWindow.removeAt(0);
      }

      if (!mounted) return;
      setState(() {
        _magnitudeUt = magnitude;
        _emfGauge = _mapMagnitudeToGauge(magnitude);
      });
      _evaluateThreat();
    }, onError: (e) {
      debugPrint('Magnetometer unavailable: $e');
    });
  }

  double _mapMagnitudeToGauge(double ut) {
    // Ambient Earth field is roughly 25-65 µT; this stretches that range
    // (plus headroom for real anomalies) onto the 0-100 dial. Display
    // convenience only — the µT figure shown alongside it is the real
    // sensor reading.
    return ((ut - 20) / 150 * 100).clamp(0, 100);
  }

  bool _isEmfAnomaly() {
    if (_magBaselineWindow.length < 10) return false; // not enough baseline yet
    final baseline =
        _magBaselineWindow.reduce((a, b) => a + b) / _magBaselineWindow.length;
    // Require the current reading to clear the baseline by a meaningful
    // margin, not just noise — real spikes from nearby active electronics
    // are usually large relative to the ambient level.
    final threshold = baseline + max(15.0, baseline * 0.5);
    return _magnitudeUt > threshold;
  }

  // ── Bluetooth LE (real nearby-device scan) ───────────────────────
  Future<void> _startBleScanning() async {
    if (!_scanning) return;
    try {
      if (await FlutterBluePlus.isSupported == false) {
        if (mounted) setState(() => _bleAvailable = false);
        return;
      }

      final granted = await _ensureBlePermissions();
      if (!granted) {
        if (mounted) setState(() => _bleAvailable = false);
        return;
      }

      _bleResultsSub?.cancel();
      _bleResultsSub = FlutterBluePlus.scanResults.listen(_onBleResults);

      if (mounted) setState(() => _bleScanning = true);
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      // Re-arm the next sweep shortly after this one ends, as long as
      // we're still in "scanning" mode.
      _bleRestartTimer?.cancel();
      _bleRestartTimer = Timer(const Duration(seconds: 6), () {
        if (mounted && _scanning) _startBleScanning();
      });
    } catch (e) {
      debugPrint('BLE scan error: $e');
      if (mounted) setState(() => _bleAvailable = false);
      _bleRestartTimer?.cancel();
      _bleRestartTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _scanning) _startBleScanning();
      });
    }
  }

  Future<bool> _ensureBlePermissions() async {
    // Android 12+ needs runtime BLUETOOTH_SCAN/CONNECT; older Android ties
    // BLE scan results to location permission. iOS handles its own
    // system prompt from NSBluetoothAlwaysUsageDescription in Info.plist.
    try {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      // Not every platform/OS version requires every one of these — treat
      // it as granted as long as nothing came back explicitly denied.
      return !statuses.values.any((s) => s.isPermanentlyDenied || s.isDenied);
    } catch (_) {
      return true; // permission_handler channel may be a no-op on some platforms; let the scan attempt surface the real error
    }
  }

  void _onBleResults(List<ScanResult> results) {
    final now = DateTime.now();
    for (final r in results) {
      final id = r.device.remoteId.str;
      final advertisedName = r.advertisementData.advName;
      final name = advertisedName.isNotEmpty
          ? advertisedName
          : (r.device.platformName.isNotEmpty ? r.device.platformName : null);

      final track = _bleTracks.putIfAbsent(id, () => _BleTrack(id: id));
      track.name = name;
      track.rssi = r.rssi;
      track.lastSeen = now;
      track.hitStreak++;
    }

    // Drop anything we haven't seen in a while so the list reflects what's
    // actually around right now, not a permanent log.
    _bleTracks.removeWhere(
      (_, t) => now.difference(t.lastSeen) > const Duration(seconds: 30),
    );

    if (!mounted) return;
    setState(() {
      if (_bleTracks.isNotEmpty) {
        final nearest =
            _bleTracks.values.reduce((a, b) => a.rssi >= b.rssi ? a : b);
        _dbm = nearest.rssi;
      }
    });
    _evaluateThreat();
  }

  /// A device is flagged "suspicious" — worth a manual look, not proof of
  /// anything — when it broadcasts no name, sits at a strong/close RSSI,
  /// and has shown up consistently rather than just once. This mirrors the
  /// category of heuristic behind Apple/Google's own "unknown tracker"
  /// alerts, not a from-scratch invention.
  List<_BleTrack> _suspiciousBleDevices() {
    return _bleTracks.values
        .where((t) => t.name == null && t.rssi > -65 && t.hitStreak >= 3)
        .toList();
  }

  double? _estimateDistanceMeters(int rssi) {
    // Standard log-distance path-loss estimate. measuredPower is a typical
    // "RSSI at 1 meter" calibration constant for BLE — real devices vary,
    // and walls/orientation/multipath mean this can be off by several
    // meters indoors. Treat it as "closer / farther," not a tape measure.
    const measuredPower = -59.0;
    const pathLossExponent = 2.0;
    if (rssi == 0) return null;
    return pow(10, (measuredPower - rssi) / (10 * pathLossExponent)).toDouble();
  }

  void _evaluateThreat() {
    if (!mounted) return;
    final suspicious = _suspiciousBleDevices();
    final emfAnomaly = _isEmfAnomaly();
    final isThreat = suspicious.isNotEmpty || emfAnomaly;

    if (isThreat && _scanStatus != 'BUG DETECTED') {
      setState(() {
        _threatCount++;
        _scanStatus = 'BUG DETECTED';
      });
      _playBeep();
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (mounted && _scanStatus == 'BUG DETECTED') {
          setState(() => _scanStatus = 'SCANNING');
        }
      });
    }
  }

  Future<void> _playBeep() async {
    final now = DateTime.now();
    if (_lastBeepAt != null && now.difference(_lastBeepAt!) < const Duration(seconds: 2)) {
      return; // debounce so a run of detections doesn't overlap beeps
    }
    _lastBeepAt = now;
    try {
      await _beepPlayer.stop();
      await _beepPlayer.play(AssetSource('sounds/beep.wav'));
    } catch (e) {
      debugPrint('Beep playback failed: $e');
    }
  }

  List<RadarDevice> get _radarDevices {
    return _bleTracks.values.map((t) {
      final proximity = ((t.rssi + 100) / 70).clamp(0.0, 1.0); // 1 = very close
      return RadarDevice(
        id: t.id,
        distance01: 1 - proximity,
        suspicious: _suspiciousBleDevices().any((s) => s.id == t.id),
      );
    }).toList();
  }

  String get _nearestRangeLabel {
    if (_bleTracks.isEmpty) return '--';
    final nearest = _bleTracks.values.reduce((a, b) => a.rssi >= b.rssi ? a : b);
    final meters = _estimateDistanceMeters(nearest.rssi);
    if (meters == null) return '--';
    return meters.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final isAlert = _scanStatus == 'BUG DETECTED';
    final screenWidth = MediaQuery.of(context).size.width;
    final radarSize = min(screenWidth - 32, 260.0);

    return Container(
      color: const Color(0xFF0D0D0D),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Color.fromRGBO(0, 255, 102, 0.08),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SecureVision',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color.fromRGBO(0, 255, 102, 0.6),
                          letterSpacing: 1.98,
                        ),
                      ),
                      const Text(
                        'BUG SCANNER',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 1.28,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isAlert
                            ? const Color(0xFFFF2244)
                            : const Color(0xFF00FF66).withOpacity(0.3),
                      ),
                      borderRadius: BorderRadius.circular(4),
                      color: isAlert
                          ? const Color(0xFFFF2244).withOpacity(0.1)
                          : const Color(0xFF00FF66).withOpacity(0.06),
                      boxShadow: [
                        BoxShadow(
                          color: isAlert
                              ? const Color(0xFFFF2244).withOpacity(0.3)
                              : const Color(0xFF00FF66).withOpacity(0.1),
                          blurRadius: isAlert ? 12 : 8,
                        ),
                      ],
                    ),
                    child: Text(
                      _scanStatus,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.44,
                        color: isAlert
                            ? const Color(0xFFFF2244)
                            : const Color(0xFF00FF66),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            // Radar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Pulse rings
                  for (int i = 1; i <= 3; i++)
                    TweenAnimationBuilder(
                      duration: Duration(seconds: 2 + i * 1),
                      tween: Tween<double>(begin: 0.0, end: 1.0),
                      builder: (context, progress, child) {
                        final scale = 0.5 + progress * 0.5;
                        return Container(
                          width: radarSize,
                          height: radarSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF00FF66).withOpacity(0.15 * (1 - progress)),
                            ),
                          ),
                          transform: Matrix4.identity()..scale(scale),
                        );
                      },
                    ),
                  RadarCanvas(size: radarSize, devices: _radarDevices),
                ],
              ),
            ),
            
            // Stats row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _buildStatCard('THREATS', _threatCount.toString(), ''),
                  const SizedBox(width: 6),
                  _buildStatCard('FREQ', '2.4', 'GHz'),
                  const SizedBox(width: 6),
                  _buildStatCard('RANGE', _nearestRangeLabel, 'm'),
                ],
              ),
            ),
            
            const SizedBox(height: 10),
            
            // Bento grid
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  // EMF card - full width
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      border: Border.all(
                        color: isAlert
                            ? const Color(0xFFFF2244).withOpacity(0.3)
                            : const Color(0xFF00FF66).withOpacity(0.1),
                      ),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: isAlert
                          ? [
                              BoxShadow(
                                color: const Color(0xFFFF2244).withOpacity(0.1),
                                blurRadius: 20,
                              ),
                            ]
                          : null,
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'EMF NEEDLE GAUGE',
                              style: TextStyle(
                                fontSize: 9,
                                color: Color.fromRGBO(0, 255, 102, 0.5),
                                letterSpacing: 1.26,
                              ),
                            ),
                            Text(
                              '${_magnitudeUt.toStringAsFixed(1)} μT',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: isAlert
                                    ? const Color(0xFFFF2244)
                                    : const Color(0xFF00FF66),
                                letterSpacing: 0.66,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        NeedleGauge(value: _emfGauge),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text(
                                'LOW',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                  letterSpacing: 0.8,
                                ),
                              ),
                              Text(
                                'MED',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Color.fromRGBO(255, 184, 0, 0.5),
                                  letterSpacing: 0.8,
                                ),
                              ),
                              Text(
                                'HIGH',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Color.fromRGBO(255, 34, 68, 0.6),
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 6),
                  
                  // Signal strength card
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      border: Border.all(
                        color: const Color(0xFF00FF66).withOpacity(0.1),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'RF SIGNAL STRENGTH',
                              style: TextStyle(
                                fontSize: 9,
                                color: Color.fromRGBO(0, 255, 102, 0.5),
                                letterSpacing: 1.26,
                              ),
                            ),
                            RichText(
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: '$_dbm',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF00FF66),
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' dBm',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w400,
                                      color: Color.fromRGBO(0, 255, 102, 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SignalBars(dbm: _dbm),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text(
                                '−100 dBm',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                ),
                              ),
                              Text(
                                '−40 dBm',
                                style: TextStyle(
                                  fontSize: 8,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 6),
                  
                  Row(
                    children: [
                      // Protocol card
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF111111),
                            border: Border.all(
                              color: const Color(0xFF00FF66).withOpacity(0.1),
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'PROTOCOLS',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color.fromRGBO(0, 255, 102, 0.5),
                                  letterSpacing: 1.08,
                                ),
                              ),
                              const SizedBox(height: 10),
                              ...['WiFi', 'Bluetooth LE', 'Zigbee', 'Z-Wave'].asMap().entries.map((entry) {
                                final index = entry.key;
                                final name = entry.value;
                                // Real status for WiFi/BLE; phones have no
                                // Zigbee/Z-Wave radio at all, so those two
                                // are always shown inactive rather than
                                // faked as scannable.
                                final active = index == 0 ? _wifiConnected : (index == 1 ? _bleScanning : false);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        name,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: active ? Colors.white : Colors.white.withOpacity(0.25),
                                        ),
                                      ),
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: active
                                              ? const Color(0xFF00FF66)
                                              : Colors.white.withOpacity(0.1),
                                          boxShadow: active
                                              ? [
                                                  BoxShadow(
                                                    color: const Color(0xFF00FF66),
                                                    blurRadius: 6,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'Zigbee/Z-Wave: no phone radio support',
                                  style: TextStyle(
                                    fontSize: 7,
                                    color: Colors.white.withOpacity(0.18),
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(width: 6),
                      
                      // Scan control card
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF111111),
                            border: Border.all(
                              color: const Color(0xFF00FF66).withOpacity(0.1),
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'SCAN CTRL',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color.fromRGBO(0, 255, 102, 0.5),
                                  letterSpacing: 1.08,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () {
                                    setState(() {
                                      _scanning = !_scanning;
                                    });
                                    if (_scanning) {
                                      _startMagnetometer();
                                      _startBleScanning();
                                    } else {
                                      _magSub?.cancel();
                                      _bleResultsSub?.cancel();
                                      _bleRestartTimer?.cancel();
                                      if (_bleScanning) FlutterBluePlus.stopScan();
                                      setState(() => _bleScanning = false);
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _scanning
                                        ? const Color(0xFF00FF66).withOpacity(0.12)
                                        : const Color(0xFFFF2244).withOpacity(0.1),
                                    foregroundColor: _scanning
                                        ? const Color(0xFF00FF66)
                                        : const Color(0xFFFF2244),
                                    side: BorderSide(
                                      color: _scanning
                                          ? const Color(0xFF00FF66).withOpacity(0.4)
                                          : const Color(0xFFFF2244).withOpacity(0.4),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                  ),
                                  child: Text(
                                    _scanning ? '⏸ PAUSE' : '▶ RESUME',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.2,
                                      fontFamily: 'JetBrainsMono',
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Center(
                                child: Text(
                                  _scanning
                                      ? (_bleAvailable ? 'ACTIVE SWEEP' : 'BLE UNAVAILABLE')
                                      : 'PAUSED',
                                  style: TextStyle(
                                    fontSize: 8,
                                    color: Colors.white.withOpacity(0.2),
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, String unit) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          border: Border.all(
            color: const Color(0xFF00FF66).withOpacity(0.1),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: Color.fromRGBO(0, 255, 102, 0.5),
                letterSpacing: 1.08,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF00FF66),
                    height: 1,
                  ),
                ),
                if (unit.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      unit,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color.fromRGBO(0, 255, 102, 0.6),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}