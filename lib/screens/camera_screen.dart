import 'package:flutter/material.dart';
import 'dart:math';

// ── Drifting AI scan box ─────────────────────────────────────────────────
class ScanBox extends StatefulWidget {
  final bool active;

  const ScanBox({super.key, required this.active});

  @override
  State<ScanBox> createState() => _ScanBoxState();
}

class _ScanBoxState extends State<ScanBox> with SingleTickerProviderStateMixin {
  int _posIndex = 0;
  bool _irDetected = false;
  late AnimationController _controller;

  final List<Map<String, double>> _targets = [
    {'top': 15.0, 'left': 10.0, 'width': 30.0, 'height': 20.0},
    {'top': 20.0, 'left': 55.0, 'width': 35.0, 'height': 25.0},
    {'top': 45.0, 'left': 30.0, 'width': 28.0, 'height': 18.0},
    {'top': 30.0, 'left': 5.0, 'width': 32.0, 'height': 22.0},
    {'top': 10.0, 'left': 40.0, 'width': 25.0, 'height': 20.0},
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    
    _controller.addListener(() {
      if (_controller.value >= 0.99 && _posIndex < _targets.length - 1) {
        setState(() {
          _posIndex = (_posIndex + 1) % _targets.length;
          _irDetected = Random().nextDouble() < 0.18;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    
    final pos = _targets[_posIndex];
    final color = _irDetected ? const Color(0xFFFF2244) : const Color(0xFF00FF66);

    return Positioned(
      top: pos['top']!,
      left: pos['left']!,
      width: pos['width']!,
      height: pos['height']!,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 1800),
        curve: Curves.easeInOutCubic,
        decoration: BoxDecoration(
          border: Border.all(
            color: color,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.25),
              blurRadius: 10,
            ),
            BoxShadow(
              color: color.withOpacity(0.06),
              blurRadius: 10,
              spreadRadius: 10,
            ),
          ],
        ),
        child: Stack(
          children: [
            // Corner brackets
            ...['topLeft', 'topRight', 'bottomLeft', 'bottomRight'].map((position) {
              return Positioned(
                top: position.contains('top') ? -1.0 : null,
                bottom: position.contains('bottom') ? -1.0 : null,
                left: position.contains('left') ? -1.0 : null,
                right: position.contains('right') ? -1.0 : null,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    border: Border(
                      top: position.contains('top') ? BorderSide(color: color, width: 2) : BorderSide.none,
                      bottom: position.contains('bottom') ? BorderSide(color: color, width: 2) : BorderSide.none,
                      left: position.contains('left') ? BorderSide(color: color, width: 2) : BorderSide.none,
                      right: position.contains('right') ? BorderSide(color: color, width: 2) : BorderSide.none,
                    ),
                  ),
                ),
              );
            }).toList(),
            
            // Label
            Positioned(
              top: -20,
              left: 0,
              child: Text(
                _irDetected ? 'IR SPIKE DETECTED' : 'AI SCANNING...',
                style: TextStyle(
                  fontSize: 8,
                  fontFamily: 'JetBrainsMono',
                  color: color,
                  letterSpacing: 0.96,
                  shadows: [
                    Shadow(
                      color: color,
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
            
            // Center crosshair
            Center(
              child: SizedBox(
                width: 12,
                height: 12,
                child: Stack(
                  children: [
                    Positioned(
                      top: 5,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 1,
                        color: color,
                      ),
                    ),
                    Positioned(
                      left: 5,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 1,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Reticle grid overlay ─────────────────────────────────────────────────
class ReticleOverlay extends StatelessWidget {
  const ReticleOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: ReticlePainter(),
      size: Size.infinite,
    );
  }
}

class ReticlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    // Grid lines
    paint.color = const Color(0xFF00FF66).withOpacity(0.08);
    for (int i = 1; i <= 4; i++) {
      final pos = i * 0.2;
      canvas.drawLine(Offset(size.width * pos, 0), Offset(size.width * pos, size.height), paint);
      canvas.drawLine(Offset(0, size.height * pos), Offset(size.width, size.height * pos), paint);
    }

    // Center reticle
    final cx = size.width / 2;
    final cy = size.height / 2;
    paint.color = const Color(0xFF00FF66).withOpacity(0.25);
    paint.strokeWidth = 1;
    canvas.drawCircle(Offset(cx, cy), 30, paint);
    
    paint.color = const Color(0xFF00FF66).withOpacity(0.5);
    canvas.drawCircle(Offset(cx, cy), 4, paint);
    
    paint.color = const Color(0xFF00FF66).withOpacity(0.3);
    paint.strokeWidth = 1;
    const crossLen = 40.0;
    const gap = 14.0;
    canvas.drawLine(Offset(cx, cy - crossLen), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + crossLen), Offset(cx, cy + gap), paint);
    canvas.drawLine(Offset(cx - crossLen, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + crossLen, cy), Offset(cx + gap, cy), paint);

    // Corner brackets
    paint.color = const Color(0xFF00FF66).withOpacity(0.5);
    paint.strokeWidth = 1.5;
    const bracketSize = 16.0;
    const bracketOffset = 8.0;
    
    // Top-left
    canvas.drawLine(Offset(bracketOffset, bracketOffset + bracketSize), 
                    Offset(bracketOffset, bracketOffset), paint);
    canvas.drawLine(Offset(bracketOffset, bracketOffset), 
                    Offset(bracketOffset + bracketSize, bracketOffset), paint);
    
    // Top-right
    canvas.drawLine(Offset(size.width - bracketOffset, bracketOffset + bracketSize), 
                    Offset(size.width - bracketOffset, bracketOffset), paint);
    canvas.drawLine(Offset(size.width - bracketOffset, bracketOffset), 
                    Offset(size.width - bracketOffset - bracketSize, bracketOffset), paint);
    
    // Bottom-left
    canvas.drawLine(Offset(bracketOffset, size.height - bracketOffset - bracketSize), 
                    Offset(bracketOffset, size.height - bracketOffset), paint);
    canvas.drawLine(Offset(bracketOffset, size.height - bracketOffset), 
                    Offset(bracketOffset + bracketSize, size.height - bracketOffset), paint);
    
    // Bottom-right
    canvas.drawLine(Offset(size.width - bracketOffset, size.height - bracketOffset - bracketSize), 
                    Offset(size.width - bracketOffset, size.height - bracketOffset), paint);
    canvas.drawLine(Offset(size.width - bracketOffset, size.height - bracketOffset), 
                    Offset(size.width - bracketOffset - bracketSize, size.height - bracketOffset), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Scanline sweep ─────────────────────────────────────────────────
class ScanLine extends StatefulWidget {
  const ScanLine({super.key});

  @override
  State<ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<ScanLine> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _animation = Tween<double>(begin: 0, end: 1).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Positioned(
          top: _animation.value * MediaQuery.of(context).size.height * 0.6,
          left: 0,
          right: 0,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Colors.transparent, Color(0xFF00FF66), Colors.transparent],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00FF66).withOpacity(0.4),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Toggle button ─────────────────────────────────────────────────
class Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final VoidCallback onChange;
  final Color color;

  const Toggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChange,
    this.color = const Color(0xFF00FF66),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChange,
      child: Container(
        padding: const EdgeInsets.all(0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withOpacity(0.7),
                letterSpacing: 1.0,
                fontFamily: 'JetBrainsMono',
              ),
            ),
            Container(
              width: 40,
              height: 22,
              decoration: BoxDecoration(
                color: value ? color.withOpacity(0.13) : Colors.white.withOpacity(0.05),
                border: Border.all(
                  color: value ? color : Colors.white.withOpacity(0.1),
                ),
                borderRadius: BorderRadius.circular(11),
                boxShadow: value
                    ? [
                        BoxShadow(
                          color: color.withOpacity(0.25),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.all(3),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value ? color : Colors.white.withOpacity(0.2),
                    boxShadow: value
                        ? [
                            BoxShadow(
                              color: color,
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Main screen ──────────────────────────────────────────────────
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _darkRoom = false;
  bool _irFilter = false;
  bool _scanning = true;
  double _distance = 2.4;
  double _irConfidence = 0;

  @override
  void initState() {
    super.initState();
    _simulateData();
  }

  void _simulateData() {
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      setState(() {
        _irConfidence = (_irFilter 
            ? 10 + Random().nextDouble() * 75
            : Random().nextDouble() * 12);
        _distance = 0.5 + Random().nextDouble() * 4.5;
      });
      _simulateData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAlert = _irConfidence > 60;
    final screenHeight = MediaQuery.of(context).size.height;
    final viewfinderHeight = screenHeight * 0.55;

    return Container(
      color: const Color(0xFF0D0D0D),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
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
                      'MODULE_02',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color.fromRGBO(0, 255, 102, 0.6),
                        letterSpacing: 1.98,
                      ),
                    ),
                    const Text(
                      'HIDDEN CAM DETECT',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                TweenAnimationBuilder(
                  duration: const Duration(milliseconds: 500),
                  tween: Tween<double>(begin: 1, end: isAlert ? 0.5 : 1),
                  builder: (context, value, child) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isAlert
                              ? const Color(0xFFFF2244)
                              : const Color(0xFF00FF66).withOpacity(0.25),
                        ),
                        borderRadius: BorderRadius.circular(4),
                        color: isAlert
                            ? const Color(0xFFFF2244).withOpacity(0.1)
                            : const Color(0xFF00FF66).withOpacity(0.05),
                      ),
                      child: Text(
                        isAlert ? 'IR SPIKE' : 'MONITORING',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.26,
                          color: isAlert
                              ? const Color(0xFFFF2244)
                              : const Color(0xFF00FF66),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          
          // Viewfinder - Fixed height
          SizedBox(
            height: viewfinderHeight,
            child: Stack(
              children: [
                // Fake camera feed
                if (!_darkRoom)
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.3, 0.4),
                        radius: 0.8,
                        colors: const [
                          Color.fromRGBO(0, 20, 10, 0.8),
                          Color.fromRGBO(0, 10, 5, 0.9),
                        ],
                      ),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF040810),
                            Color(0xFF060C08),
                            Color(0xFF08080C),
                          ],
                        ),
                      ),
                    ),
                  ),
                
                // IR simulation blobs
                if (_irFilter)
                  ..._buildIRBlobs(isAlert),
                
                // Scanline
                if (_scanning) const ScanLine(),
                
                // Reticle
                const ReticleOverlay(),
                
                // AI scan box
                if (_scanning) const ScanBox(active: true),
                
                // HUD overlays - top
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // IR confidence
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          border: Border.all(
                            color: const Color(0xFF00FF66).withOpacity(0.2),
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'IR CONFIDENCE',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(0, 255, 102, 0.6),
                                letterSpacing: 0.96,
                              ),
                            ),
                            const SizedBox(height: 3),
                            RichText(
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: _irConfidence.toInt().toString(),
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: isAlert
                                          ? const Color(0xFFFF2244)
                                          : const Color(0xFF00FF66),
                                      height: 1,
                                    ),
                                  ),
                                  const TextSpan(
                                    text: '%',
                                    style: TextStyle(fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 80,
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                child: FractionallySizedBox(
                                  widthFactor: _irConfidence / 100,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: isAlert
                                          ? const Color(0xFFFF2244)
                                          : const Color(0xFF00FF66),
                                      borderRadius: BorderRadius.circular(2),
                                      boxShadow: [
                                        BoxShadow(
                                          color: isAlert
                                              ? const Color(0xFFFF2244)
                                              : const Color(0xFF00FF66),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      // Spectrum indicator
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          border: Border.all(
                            color: const Color(0xFF00FF66).withOpacity(0.15),
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'SPECTRUM',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(0, 255, 102, 0.6),
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: ['VIS', 'NIR', 'IR'].map((band) {
                                final isActive = _irFilter && band == 'IR';
                                return Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 1),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? const Color(0xFFFF2244).withOpacity(0.3)
                                        : const Color(0xFF00FF66).withOpacity(0.08),
                                    border: Border.all(
                                      color: isActive
                                          ? const Color(0xFFFF2244)
                                          : const Color(0xFF00FF66).withOpacity(0.2),
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    band,
                                    style: TextStyle(
                                      fontSize: 7,
                                      color: isActive
                                          ? const Color(0xFFFF2244)
                                          : const Color(0xFF00FF66).withOpacity(0.6),
                                      letterSpacing: 0.42,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                // HUD overlays - bottom
                Positioned(
                  bottom: 10,
                  left: 10,
                  right: 10,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.06),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: const [
                            Text(
                              'REC ',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(255, 255, 255, 0.35),
                                letterSpacing: 0.8,
                              ),
                            ),
                            Text(
                              '●',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color(0xFFFF2244),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              '00:04:22',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(255, 255, 255, 0.25),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.06),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '940nm BAND',
                          style: TextStyle(
                            fontSize: 8,
                            color: Color.fromRGBO(0, 255, 102, 0.5),
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Glassmorphism control panel - Scrollable
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                children: [
                  // Toggles row
                  Row(
                    children: [
                      Expanded(
                        child: _buildToggleCard(
                          title: 'DARK ROOM MODE',
                          value: _darkRoom,
                          onChanged: () => setState(() => _darkRoom = !_darkRoom),
                          color: const Color(0xFFFFB800),
                          status: _darkRoom ? 'ENABLED' : 'DISABLED',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildToggleCard(
                          title: 'IR FILTER',
                          value: _irFilter,
                          onChanged: () => setState(() => _irFilter = !_irFilter),
                          color: const Color(0xFFFF2244),
                          status: _irFilter ? '940nm ACTIVE' : 'OFF',
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Distance slider
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.03),
                      border: Border.all(
                        color: const Color(0xFF00FF66).withOpacity(0.08),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'ESTIMATED DISTANCE TO LENS',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(0, 255, 102, 0.5),
                                letterSpacing: 1.12,
                              ),
                            ),
                            RichText(
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: _distance.toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF00FF66),
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' m',
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
                        const SizedBox(height: 8),
                        // Track
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Stack(
                            children: [
                              FractionallySizedBox(
                                widthFactor: _distance / 5,
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF00FF66), Color.fromRGBO(0, 255, 102, 0.4)],
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF00FF66).withOpacity(0.5),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: (_distance / 5) * 100 - 6,
                                top: -4,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(0xFF00FF66),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0xFF00FF66),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text(
                                '0.5m',
                                style: TextStyle(
                                  fontSize: 7,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                ),
                              ),
                              Text(
                                '5.0m',
                                style: TextStyle(
                                  fontSize: 7,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleCard({
    required String title,
    required bool value,
    required VoidCallback onChanged,
    required Color color,
    required String status,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        border: Border.all(
          color: value ? color.withOpacity(0.3) : Colors.white.withOpacity(0.06),
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: value
            ? [
                BoxShadow(
                  color: color.withOpacity(0.1),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 8,
              color: Colors.white.withOpacity(0.35),
              letterSpacing: 0.96,
            ),
          ),
          const SizedBox(height: 8),
          Toggle(
            label: '',
            value: value,
            onChange: onChanged,
            color: color,
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: TextStyle(
              fontSize: 8,
              color: value ? color : Colors.white.withOpacity(0.2),
              letterSpacing: 0.64,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildIRBlobs(bool isAlert) {
    final screenHeight = MediaQuery.of(context).size.height * 0.55;
    final screenWidth = MediaQuery.of(context).size.width;
    
    final blobs = [
      {'top': 0.28, 'left': 0.42, 'size': 18.0, 'glow': isAlert ? const Color(0xFFFF2244) : const Color(0xFF00FF66)},
      {'top': 0.55, 'left': 0.20, 'size': 10.0, 'glow': const Color(0xFF00FF66).withOpacity(0.3)},
    ];
    
    return blobs.map((b) {
      return Positioned(
        top: (b['top'] as double) * screenHeight,
        left: (b['left'] as double) * screenWidth,
        child: TweenAnimationBuilder(
          duration: const Duration(milliseconds: 1500),
          tween: Tween<double>(begin: 0.5, end: 1.0),
          builder: (context, value, child) {
            final size = (b['size'] as double) * (0.5 + value * 0.5);
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (b['glow'] as Color).withOpacity(0.5),
                boxShadow: [
                  BoxShadow(
                    color: b['glow'] as Color,
                    blurRadius: 20,
                  ),
                  BoxShadow(
                    color: (b['glow'] as Color).withOpacity(0.5),
                    blurRadius: 40,
                  ),
                ],
              ),
            );
          },
          child: null,
        ),
      );
    }).toList();
  }
}