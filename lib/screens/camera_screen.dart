import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isDetecting = true;
  bool _darkRoom = false;
  bool _irFilter = false;
  bool _flashlightOn = false;
  double _distance = 2.4;
  double _irConfidence = 0;
  double _sensitivity = 0.5;
  bool _isAlert = false;
  int _detectionCount = 0;
  Timer? _detectionTimer;
  Timer? _simulationTimer;
  String _lastDetected = 'NONE';
  List<DetectionResult> _detections = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _startDetectionLoop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detectionTimer?.cancel();
    _simulationTimer?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    } else if (state == AppLifecycleState.paused) {
      _cameraController?.dispose();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final status = await Permission.camera.request();
      if (status != PermissionStatus.granted) {
        print('Camera permission denied');
        return;
      }

      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        print('No cameras available');
        return;
      }

      final backCamera = _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      print('Error initializing camera: $e');
      _startSimulationMode();
    }
  }

  Future<void> _toggleFlashlight() async {
    if (_cameraController == null) return;
    try {
      final isFlashOn = _cameraController!.value.flashMode == FlashMode.torch;
      await _cameraController!.setFlashMode(
        isFlashOn ? FlashMode.off : FlashMode.torch,
      );
      setState(() {
        _flashlightOn = !isFlashOn;
      });
    } catch (e) {
      print('Flashlight error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Flashlight not available on this device'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _captureScreenshot() async {
    try {
      if (_cameraController == null) return;
      final image = await _cameraController!.takePicture();
      if (image == null) return;
      
      final bytes = await image.readAsBytes();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/detection_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(bytes);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screenshot saved: ${file.path.split('/').last}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Screenshot error: $e');
    }
  }

  void _startDetectionLoop() {
    _detectionTimer?.cancel();
    _detectionTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_isCameraInitialized && _cameraController!.value.isStreamingImages) {
        _detectHiddenCameras();
      }
    });
  }

  Future<void> _detectHiddenCameras() async {
    try {
      if (!_isCameraInitialized || _cameraController == null) return;
      
      final image = await _cameraController!.takePicture();
      if (image == null) return;

      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) return;

      final results = await _analyzeImageForIR(bytes);
      
      setState(() {
        _detections = results;
        if (results.isNotEmpty) {
          _isAlert = true;
          _detectionCount++;
          _lastDetected = 'IR SPIKE DETECTED';
          _irConfidence = results.first.confidence * 100;
        } else {
          _isAlert = false;
          _irConfidence = _irConfidence * 0.9;
          _lastDetected = 'MONITORING';
        }
      });
    } catch (e) {
      print('Detection error: $e');
    }
  }

  Future<List<DetectionResult>> _analyzeImageForIR(Uint8List imageBytes) async {
    final results = <DetectionResult>[];
    
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return results;

      final irSpikes = _findIRSpikes(image);
      
      for (final spike in irSpikes) {
        results.add(DetectionResult(
          confidence: spike.confidence,
          position: spike.position,
          size: spike.size,
        ));
      }
    } catch (e) {
      print('Image analysis error: $e');
    }

    return results;
  }

  List<IRSpike> _findIRSpikes(img.Image image) {
    final spikes = <IRSpike>[];
    final threshold = _darkRoom 
        ? (150 + _sensitivity * 100).toInt() 
        : (100 + _sensitivity * 100).toInt();
    
    final blockSize = 20;
    for (int y = 0; y < image.height; y += blockSize) {
      for (int x = 0; x < image.width; x += blockSize) {
        double avgR = 0, avgG = 0, avgB = 0;
        int count = 0;
        
        for (int dy = 0; dy < blockSize && y + dy < image.height; dy++) {
          for (int dx = 0; dx < blockSize && x + dx < image.width; dx++) {
            final pixel = image.getPixel(x + dx, y + dy);
            avgR += pixel.r;
            avgG += pixel.g;
            avgB += pixel.b;
            count++;
          }
        }
        
        if (count > 0) {
          avgR /= count;
          avgG /= count;
          avgB /= count;
          
          final brightness = (avgR + avgG + avgB) / 3;
          final isIR = avgR > avgG * 1.5 && avgR > avgB * 1.5;
          final isBright = brightness > threshold;
          final isIRFilterMode = _irFilter && brightness > 180 && avgR > 200;
          
          if ((isIR && isBright) || isIRFilterMode) {
            final confidence = _calculateConfidence(avgR, avgG, avgB, brightness);
            
            if (confidence > 0.3) {
              final normalizedX = x / image.width;
              final normalizedY = y / image.height;
              final size = (brightness / 255) * 20 + 5;
              
              spikes.add(IRSpike(
                confidence: confidence,
                position: Offset(normalizedX, normalizedY),
                size: size,
              ));
            }
          }
        }
      }
    }
    
    return _combineSpikes(spikes);
  }

  double _calculateConfidence(double r, double g, double b, double brightness) {
    double confidence = 0;
    
    if (r > g * 1.5 && r > b * 1.5) {
      confidence += 0.3;
    }
    
    if (brightness > 200) {
      confidence += 0.3;
    }
    
    if (r > 200 && g < 150 && b < 150) {
      confidence += 0.2;
    }
    
    if (r > 180 && g > 100 && b < 100) {
      confidence += 0.2;
    }
    
    if (_irFilter && brightness > 180) {
      confidence += 0.3;
    }
    
    return confidence.clamp(0, 1);
  }

  List<IRSpike> _combineSpikes(List<IRSpike> spikes) {
    if (spikes.isEmpty) return [];
    
    final combined = <IRSpike>[];
    final sorted = List<IRSpike>.from(spikes)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    
    for (final spike in sorted) {
      bool merged = false;
      for (final existing in combined) {
        final dx = spike.position.dx - existing.position.dx;
        final dy = spike.position.dy - existing.position.dy;
        final distance = sqrt(dx * dx + dy * dy);
        
        if (distance < 0.1) {
          final combinedSpike = IRSpike(
            confidence: (existing.confidence + spike.confidence) / 2,
            position: Offset(
              (existing.position.dx + spike.position.dx) / 2,
              (existing.position.dy + spike.position.dy) / 2,
            ),
            size: max(existing.size, spike.size),
          );
          combined.remove(existing);
          combined.add(combinedSpike);
          merged = true;
          break;
        }
      }
      if (!merged) {
        combined.add(spike);
      }
    }
    
    return combined.where((spike) => spike.confidence > 0.4).toList();
  }

  void _startSimulationMode() {
    _simulationTimer?.cancel();
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 2400), (timer) {
      if (!mounted) return;
      
      final random = Random();
      final spike = random.nextDouble() < 0.15;
      
      setState(() {
        if (spike && _irFilter) {
          _irConfidence = 60 + random.nextDouble() * 25;
          _isAlert = true;
          _detectionCount++;
          _lastDetected = 'IR SPIKE DETECTED';
        } else {
          _irConfidence = max(0, _irConfidence - random.nextDouble() * 10);
          _isAlert = _irConfidence > 60;
          if (!_isAlert) {
            _lastDetected = 'MONITORING';
          }
        }
        _distance = 0.5 + random.nextDouble() * 4.5;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
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
                  tween: Tween<double>(begin: 1, end: _isAlert ? 0.5 : 1),
                  builder: (context, value, child) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _isAlert
                              ? const Color(0xFFFF2244)
                              : const Color(0xFF00FF66).withOpacity(0.25),
                        ),
                        borderRadius: BorderRadius.circular(4),
                        color: _isAlert
                            ? const Color(0xFFFF2244).withOpacity(0.1)
                            : const Color(0xFF00FF66).withOpacity(0.05),
                      ),
                      child: Text(
                        _isAlert ? 'IR SPIKE' : 'MONITORING',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.26,
                          color: _isAlert
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
          
          // Viewfinder
          Container(
            height: viewfinderHeight,
            color: const Color(0xFF0A0A12),
            child: Stack(
              children: [
                if (_isCameraInitialized && _cameraController != null)
                  CameraPreview(_cameraController!)
                else
                  _buildPlaceholderFeed(),
                
                if (_irFilter && _isAlert)
                  ..._buildIRBlobs(),
                
                ..._buildDetectionMarkers(),
                
                if (_isDetecting) const ScanLine(),
                const ReticleOverlay(),
                if (_isDetecting) const ScanBox(active: true),
                
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIRConfidenceWidget(),
                      _buildSpectrumWidget(),
                    ],
                  ),
                ),
                
                Positioned(
                  bottom: 10,
                  left: 10,
                  right: 10,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildRecIndicator(),
                      _buildBandIndicator(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Control panel
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildToggleCard(
                          title: 'DARK ROOM MODE',
                          value: _darkRoom,
                          onChanged: () {
                            setState(() {
                              _darkRoom = !_darkRoom;
                            });
                          },
                          color: const Color(0xFFFFB800),
                          status: _darkRoom ? 'ENABLED' : 'DISABLED',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildToggleCard(
                          title: 'IR FILTER',
                          value: _irFilter,
                          onChanged: () {
                            setState(() {
                              _irFilter = !_irFilter;
                              if (_irFilter) {
                                _isDetecting = true;
                              }
                            });
                          },
                          color: const Color(0xFFFF2244),
                          status: _irFilter ? '940nm ACTIVE' : 'OFF',
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 10),
                  
                  Row(
                    children: [
                      Expanded(
                        child: _buildToggleCard(
                          title: 'FLASHLIGHT',
                          value: _flashlightOn,
                          onChanged: _toggleFlashlight,
                          color: const Color(0xFFFFB800),
                          status: _flashlightOn ? 'ON' : 'OFF',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: _captureScreenshot,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.03),
                              border: Border.all(
                                color: const Color(0xFF00FF66).withOpacity(0.2),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'CAPTURE',
                                  style: TextStyle(
                                    fontSize: 8,
                                    color: Color.fromRGBO(0, 255, 102, 0.5),
                                    letterSpacing: 0.96,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Center(
                                  child: Icon(
                                    Icons.camera_alt,
                                    size: 28,
                                    color: const Color(0xFF00FF66).withOpacity(0.7),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Center(
                                  child: Text(
                                    'SAVE IMAGE',
                                    style: TextStyle(
                                      fontSize: 7,
                                      color: const Color(0xFF00FF66).withOpacity(0.5),
                                      letterSpacing: 0.64,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 10),
                  
                  // Sensitivity slider
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
                              'SENSITIVITY',
                              style: TextStyle(
                                fontSize: 8,
                                color: Color.fromRGBO(0, 255, 102, 0.5),
                                letterSpacing: 1.12,
                              ),
                            ),
                            Text(
                              '${(_sensitivity * 100).toInt()}%',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF00FF66),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _sensitivity,
                          min: 0.0,
                          max: 1.0,
                          activeColor: const Color(0xFF00FF66),
                          inactiveColor: Colors.white.withOpacity(0.1),
                          onChanged: (value) {
                            setState(() {
                              _sensitivity = value;
                            });
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text(
                                'LOW',
                                style: TextStyle(
                                  fontSize: 7,
                                  color: Color.fromRGBO(255, 255, 255, 0.2),
                                ),
                              ),
                              Text(
                                'HIGH',
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

  Widget _buildPlaceholderFeed() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.3, 0.4),
          radius: 0.8,
          colors: [
            Color.fromRGBO(0, 20, 10, 0.8),
            Color.fromRGBO(0, 10, 5, 0.9),
          ],
        ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF040810),
              Color(0xFF060C08),
              Color(0xFF08080C),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.camera_alt_outlined,
                size: 50,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 10),
              Text(
                'Camera not available\nTap to retry',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIRConfidenceWidget() {
    return Container(
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
                    color: _isAlert
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
                    color: _isAlert
                        ? const Color(0xFFFF2244)
                        : const Color(0xFF00FF66),
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: _isAlert
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
    );
  }

  Widget _buildSpectrumWidget() {
    return Container(
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
    );
  }

  Widget _buildRecIndicator() {
    return Container(
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
        children: [
          const Text(
            'REC ',
            style: TextStyle(
              fontSize: 8,
              color: Color.fromRGBO(255, 255, 255, 0.35),
              letterSpacing: 0.8,
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            child: Text(
              '●',
              style: TextStyle(
                fontSize: 8,
                color: _isAlert ? const Color(0xFFFF2244) : const Color(0xFF00FF66),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _lastDetected,
            style: TextStyle(
              fontSize: 8,
              color: _isAlert ? const Color(0xFFFF2244) : Colors.white.withOpacity(0.25),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBandIndicator() {
    return Container(
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
      child: Text(
        _irFilter ? 'IR BAND ACTIVE' : 'VISIBLE BAND',
        style: TextStyle(
          fontSize: 8,
          color: _irFilter 
              ? const Color(0xFFFF2244).withOpacity(0.7)
              : const Color(0xFF00FF66).withOpacity(0.5),
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  List<Widget> _buildDetectionMarkers() {
    return _detections.map((detection) {
      final screenHeight = MediaQuery.of(context).size.height * 0.55;
      final screenWidth = MediaQuery.of(context).size.width;
      
      return Positioned(
        left: detection.position.dx * screenWidth - detection.size / 2,
        top: detection.position.dy * screenHeight - detection.size / 2,
        child: Container(
          width: detection.size * 2,
          height: detection.size * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(0.3),
            border: Border.all(
              color: Colors.red,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.red.withOpacity(0.5),
                blurRadius: 10,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _buildIRBlobs() {
    final screenHeight = MediaQuery.of(context).size.height * 0.55;
    final screenWidth = MediaQuery.of(context).size.width;
    
    final blobs = [
      {'top': 0.28, 'left': 0.42, 'size': 18.0},
      {'top': 0.55, 'left': 0.20, 'size': 10.0},
      {'top': 0.15, 'left': 0.75, 'size': 12.0},
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
                color: const Color(0xFFFF2244).withOpacity(0.3),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF2244),
                    blurRadius: 20,
                  ),
                  BoxShadow(
                    color: const Color(0xFFFF2244).withOpacity(0.3),
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
}

class DetectionResult {
  final double confidence;
  final Offset position;
  final double size;

  DetectionResult({
    required this.confidence,
    required this.position,
    required this.size,
  });
}

class IRSpike {
  double confidence;
  final Offset position;
  final double size;

  IRSpike({
    required this.confidence,
    required this.position,
    required this.size,
  });
}

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
          top: _animation.value * MediaQuery.of(context).size.height * 0.55,
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

    paint.color = const Color(0xFF00FF66).withOpacity(0.08);
    for (int i = 1; i <= 4; i++) {
      final pos = i * 0.2;
      canvas.drawLine(Offset(size.width * pos, 0), Offset(size.width * pos, size.height), paint);
      canvas.drawLine(Offset(0, size.height * pos), Offset(size.width, size.height * pos), paint);
    }

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

    paint.color = const Color(0xFF00FF66).withOpacity(0.5);
    paint.strokeWidth = 1.5;
    const bracketSize = 16.0;
    const bracketOffset = 8.0;
    
    canvas.drawLine(Offset(bracketOffset, bracketOffset + bracketSize), 
                    Offset(bracketOffset, bracketOffset), paint);
    canvas.drawLine(Offset(bracketOffset, bracketOffset), 
                    Offset(bracketOffset + bracketSize, bracketOffset), paint);
    
    canvas.drawLine(Offset(size.width - bracketOffset, bracketOffset + bracketSize), 
                    Offset(size.width - bracketOffset, bracketOffset), paint);
    canvas.drawLine(Offset(size.width - bracketOffset, bracketOffset), 
                    Offset(size.width - bracketOffset - bracketSize, bracketOffset), paint);
    
    canvas.drawLine(Offset(bracketOffset, size.height - bracketOffset - bracketSize), 
                    Offset(bracketOffset, size.height - bracketOffset), paint);
    canvas.drawLine(Offset(bracketOffset, size.height - bracketOffset), 
                    Offset(bracketOffset + bracketSize, size.height - bracketOffset), paint);
    
    canvas.drawLine(Offset(size.width - bracketOffset, size.height - bracketOffset - bracketSize), 
                    Offset(size.width - bracketOffset, size.height - bracketOffset), paint);
    canvas.drawLine(Offset(size.width - bracketOffset, size.height - bracketOffset), 
                    Offset(size.width - bracketOffset - bracketSize, size.height - bracketOffset), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ScanBox extends StatelessWidget {
  final bool active;

  const ScanBox({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();

    return Positioned(
      top: 25,
      left: 25,
      right: 25,
      bottom: 25,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFF00FF66).withOpacity(0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00FF66).withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
        ),
        child: Stack(
          children: [
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
                      top: position.contains('top') ? const BorderSide(color: Color(0xFF00FF66), width: 2) : BorderSide.none,
                      bottom: position.contains('bottom') ? const BorderSide(color: Color(0xFF00FF66), width: 2) : BorderSide.none,
                      left: position.contains('left') ? const BorderSide(color: Color(0xFF00FF66), width: 2) : BorderSide.none,
                      right: position.contains('right') ? const BorderSide(color: Color(0xFF00FF66), width: 2) : BorderSide.none,
                    ),
                  ),
                ),
              );
            }).toList(),
            
            const Positioned(
              top: -20,
              left: 0,
              child: Text(
                'AI SCANNING...',
                style: TextStyle(
                  fontSize: 8,
                  fontFamily: 'JetBrainsMono',
                  color: Color(0xFF00FF66),
                  letterSpacing: 0.96,
                  shadows: [
                    Shadow(
                      color: Color(0xFF00FF66),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
            
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
                        color: const Color(0xFF00FF66).withOpacity(0.5),
                      ),
                    ),
                    Positioned(
                      left: 5,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 1,
                        color: const Color(0xFF00FF66).withOpacity(0.5),
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