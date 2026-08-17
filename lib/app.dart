import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/radar_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/network_screen.dart';
import 'components/bottom_nav.dart';

enum Screen { radar, camera, network }

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with SingleTickerProviderStateMixin {
  Screen _activeScreen = Screen.radar;
  Screen? _prevScreen;
  bool _transitioning = false;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _navigate(Screen screen) {
    if (screen == _activeScreen || _transitioning) return;
    setState(() {
      _transitioning = true;
      _prevScreen = _activeScreen;
    });
    _animationController.forward(from: 0).then((_) {
      setState(() {
        _activeScreen = screen;
        _transitioning = false;
        _animationController.value = 0;
      });
    });
  }

  Widget _getScreen(Screen screen) {
    switch (screen) {
      case Screen.radar:
        return const RadarScreen();
      case Screen.camera:
        return const CameraScreen();
      case Screen.network:
        return const NetworkScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Get the status bar height
    final statusBarHeight = MediaQuery.of(context).padding.top;
    
    return Scaffold(
      body: Center(
        child: Container(
          width: MediaQuery.of(context).size.width > 390
              ? 390
              : MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height > 844
              ? 844
              : MediaQuery.of(context).size.height,
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0D),
            borderRadius: BorderRadius.circular(
              MediaQuery.of(context).size.width > 390 ? 44 : 0,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 255, 102, 0.08),
                spreadRadius: 0,
                blurRadius: 0,
                offset: Offset(0, 0),
              ),
              BoxShadow(
                color: Colors.black,
                spreadRadius: 0,
                blurRadius: 60,
              ),
            ],
          ),
          child: Stack(
            children: [
              // Scan line overlay
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      MediaQuery.of(context).size.width > 390 ? 44 : 0,
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color.fromRGBO(0, 0, 0, 0.03),
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.5, 1.0],
                    ),
                  ),
                  child: CustomPaint(
                    painter: ScanLinePainter(),
                  ),
                ),
              ),
              
              // Screen area - starts after status bar space
              Positioned(
                top: statusBarHeight,  // Preserve space for status bar
                left: 0,
                right: 0,
                bottom: 72,
                child: ClipRect(
                  child: AnimatedOpacity(
                    opacity: _transitioning ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: AnimatedScale(
                      scale: _transitioning ? 0.97 : 1.0,
                      duration: const Duration(milliseconds: 180),
                      child: _getScreen(_activeScreen),
                    ),
                  ),
                ),
              ),
              
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: BottomNav(
                  active: _activeScreen,
                  onNavigate: _navigate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScanLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color.fromRGBO(0, 0, 0, 0.03);
    
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}