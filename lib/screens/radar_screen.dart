import 'package:flutter/material.dart';
import 'dart:math';

// ── Radar Canvas ─────────────────────────────────────────────────
class RadarCanvas extends StatefulWidget {
  final double size;

  const RadarCanvas({super.key, required this.size});

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
    
    final random = Random();
    _blips = List.generate(6, (_) {
      final a = random.nextDouble() * 2 * pi;
      final d = (0.3 + random.nextDouble() * 0.6) * (widget.size / 2 - 4);
      return _Blip(
        x: widget.size / 2 + cos(a) * d,
        y: widget.size / 2 + sin(a) * d,
        age: random.nextDouble() * 360,
        r: 2 + random.nextDouble() * 2,
      );
    });
    
    _controller.repeat();
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
  _Blip({required this.x, required this.y, required this.age, required this.r});
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
        paint.color = const Color(0xFF00FF66).withOpacity(fade);
        paint.style = PaintingStyle.fill;
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * fade);
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

// ── Signal bar strip ─────────────────────────────────────────────
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
  double _emf = 22;
  int _dbm = -58;
  double _microtesla = 12.4;
  bool _scanning = true;
  int _threatCount = 0;
  String _scanStatus = 'SCANNING';
  double _radarSize = 240;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    
    _simulateData();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _simulateData() {
    if (!_scanning) return;
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final spike = Random().nextDouble() < 0.08;
      final newEmf = spike ? 75 + Random().nextDouble() * 20 : 15 + Random().nextDouble() * 30;
      setState(() {
        _emf = newEmf;
        _microtesla = 2 + Random().nextDouble() * (spike ? 60 : 20);
        _dbm = -40 - Random().nextInt(55);
        
        if (spike) {
          _threatCount++;
          _scanStatus = 'THREAT DETECTED';
          Future.delayed(const Duration(milliseconds: 2200), () {
            if (mounted) {
              setState(() {
                _scanStatus = 'SCANNING';
              });
            }
          });
        }
      });
      _simulateData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAlert = _scanStatus == 'THREAT DETECTED';
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
                  RadarCanvas(size: radarSize),
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
                  _buildStatCard('RANGE', '15', 'm'),
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
                              '${_microtesla.toStringAsFixed(1)} μT',
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
                        NeedleGauge(value: _emf),
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
                              ...['WiFi 6', 'BT 5.3', 'Zigbee', 'Z-Wave'].asMap().entries.map((entry) {
                                final index = entry.key;
                                final name = entry.value;
                                final active = index < 2;
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
                                      if (_scanning) {
                                        _simulateData();
                                      }
                                    });
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
                                  _scanning ? 'ACTIVE SWEEP' : 'PAUSED',
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