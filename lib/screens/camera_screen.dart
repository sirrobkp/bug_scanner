import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

// NOTE ON WHAT THIS SCREEN CAN AND CAN'T DO:
// Phone camera sensors sit behind an IR-cut filter, so they are not true IR
// cameras. What this module actually does is two complementary, real
// heuristics run on the *live* camera stream (no more still-photo polling):
//   1. IR-LEAK SPOT SCAN: most phone sensors still leak a little near-IR
//      through the cut filter. In a dark room, an active IR illuminator
//      (common in cheap hidden cams for night vision) shows up as a small,
//      steady, disproportionately bright spot in the luma channel. We look
//      for spatially-isolated brightness spikes relative to their local
//      surroundings, and require them to persist across several frames at a
//      stable position (real emitters are steady; sensor noise / motion
//      artifacts are not) before we ever raise an alert.
//   2. LENS GLINT SCAN (flashlight mode): shining a light and looking for a
//      tiny, near-white specular highlight is the standard manual technique
//      for spotting a hidden lens. We reproduce that: with the flashlight
//      on, we look for very small, very bright, near-neutral-color points.
// Neither of these is a certified detector. They reduce false negatives vs.
// "look for anything reddish" (the original heuristic, which fires on any
// warm-colored object) and false positives vs. "no temporal check" (the
// original, which alerted on a single frame). They are still heuristics —
// treat alerts as "worth a closer manual look," not proof.

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
  double _distance = 0;
  double _irConfidence = 0;
  double _sensitivity = 0.5;
  bool _isAlert = false;
  int _detectionCount = 0;
  Timer? _simulationTimer;
  String _lastDetected = 'NONE';
  List<DetectionResult> _detections = [];

  // True only when we've fallen back to synthetic data because the camera
  // could not be initialized. The UI must always make this visible — it is
  // never mixed silently into real results.
  bool _isSimulated = false;

  // Frame-processing state for the live image stream.
  bool _isStreamBusy = false;
  int _frameCounter = 0;
  static const int _processEveryNFrames = 4; // throttle: ~5-7fps of analysis at 30fps capture
  DateTime? _lastAnalysisAt;

  // Rolling history of spike centroids (normalized 0-1 coords) per recent
  // analyzed frame, used to require temporal persistence before alerting.
  final List<List<_Spike>> _recentFrameSpikes = [];
  static const int _persistenceWindow = 6;
  static const int _persistenceRequired = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _simulationTimer?.cancel();
    _stopStreamSafely();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    } else if (state == AppLifecycleState.paused) {
      _stopStreamSafely();
      _cameraController?.dispose();
      _isCameraInitialized = false;
    }
  }

  Future<void> _stopStreamSafely() async {
    try {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController!.stopImageStream();
      }
    } catch (_) {
      // Already stopped / controller torn down — nothing to do.
    }
  }

  Future<void> _initializeCamera() async {
    _simulationTimer?.cancel();
    try {
      final status = await Permission.camera.request();
      if (status != PermissionStatus.granted) {
        print('Camera permission denied');
        if (mounted) {
          setState(() => _isSimulated = true);
        }
        _startSimulationMode();
        return;
      }

      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        print('No cameras available');
        if (mounted) {
          setState(() => _isSimulated = true);
        }
        _startSimulationMode();
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
        // yuv420 on Android gives us direct access to the luma plane, which
        // is all the spot-scan needs. iOS ignores this and always delivers
        // bgra8888, which we also handle in _extractFrameSamples.
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onCameraFrame);

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _isSimulated = false;
          _recentFrameSpikes.clear();
          _detections = [];
          _isAlert = false;
          _irConfidence = 0;
          _lastDetected = 'MONITORING';
        });
      }
    } catch (e) {
      print('Error initializing camera: $e');
      if (mounted) {
        setState(() => _isSimulated = true);
      }
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
    if (_cameraController == null || !_isCameraInitialized) return;
    // takePicture() can't run concurrently with the analysis stream on all
    // platforms, so we pause the stream for the single still capture and
    // resume it right after — this only happens on an explicit user tap,
    // never inside the detection loop itself.
    final wasStreaming = _cameraController!.value.isStreamingImages;
    try {
      if (wasStreaming) {
        await _cameraController!.stopImageStream();
      }

      final image = await _cameraController!.takePicture();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save screenshot'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (wasStreaming && _cameraController != null && _isCameraInitialized) {
        try {
          await _cameraController!.startImageStream(_onCameraFrame);
        } catch (e) {
          print('Could not resume stream: $e');
        }
      }
    }
  }

  // Called by the camera plugin for every captured frame. We throttle here
  // rather than in a separate Timer, so we're always analyzing the *latest*
  // frame instead of racing a fixed clock against a slow takePicture() call.
  void _onCameraFrame(CameraImage image) {
    if (!_isDetecting) return;
    _frameCounter++;
    if (_frameCounter % _processEveryNFrames != 0) return;
    if (_isStreamBusy) return; // drop frame if previous analysis still running
    _isStreamBusy = true;

    // Do the heavy pixel work off the UI isolate's critical path by yielding
    // first, so scrolling/animation doesn't stall waiting on analysis.
    Future(() => _analyzeFrame(image)).whenComplete(() {
      _isStreamBusy = false;
    });
  }

  void _analyzeFrame(CameraImage image) {
    try {
      final now = DateTime.now();
      _lastAnalysisAt = now;

      final samples = _extractFrameSamples(image);
      if (samples == null) return;

      final spotSpikes = _findSpotSpikes(samples);
      final glintSpikes = _flashlightOn ? _findGlintSpikes(samples) : <_Spike>[];

      final frameSpikes = [...spotSpikes, ...glintSpikes];
      _recentFrameSpikes.add(frameSpikes);
      if (_recentFrameSpikes.length > _persistenceWindow) {
        _recentFrameSpikes.removeAt(0);
      }

      final persistent = _findPersistentSpikes();

      if (!mounted) return;
      setState(() {
        _detections = persistent
            .map((s) => DetectionResult(
                  confidence: s.confidence,
                  position: s.position,
                  size: s.size,
                ))
            .toList();

        if (_detections.isNotEmpty) {
          final best = _detections.reduce(
              (a, b) => a.confidence >= b.confidence ? a : b);
          _isAlert = true;
          _detectionCount++;
          _lastDetected = _flashlightOn && glintSpikes.isNotEmpty
              ? 'LENS GLINT DETECTED'
              : 'IR SPIKE DETECTED';
          _irConfidence = best.confidence * 100;
          // Rough proxy only: a larger, brighter apparent spot generally
          // sits closer to the lens. This is NOT a real distance
          // measurement (that needs depth/LiDAR hardware) — it's a
          // relative cue to help the user close in on the source.
          _distance = (5.0 - (best.size / 30.0) * 4.5).clamp(0.3, 5.0);
        } else {
          _isAlert = false;
          _irConfidence = max(0, _irConfidence - 8);
          _lastDetected = 'MONITORING';
        }
      });
    } catch (e) {
      print('Frame analysis error: $e');
    }
  }

  // Requires a spike to show up in roughly the same spot across most of the
  // last few analyzed frames before we trust it. This is what turns a noisy
  // single-frame color heuristic into something resistant to sensor noise,
  // camera shake, and momentary reflections.
  List<_Spike> _findPersistentSpikes() {
    if (_recentFrameSpikes.length < _persistenceRequired) return [];

    final latest = _recentFrameSpikes.last;
    final result = <_Spike>[];

    for (final candidate in latest) {
      int hits = 0;
      double confSum = 0;
      for (final frame in _recentFrameSpikes) {
        final match = frame.where((s) =>
            (s.position - candidate.position).distance < 0.08);
        if (match.isNotEmpty) {
          hits++;
          confSum += match.first.confidence;
        }
      }
      if (hits >= _persistenceRequired) {
        result.add(_Spike(
          position: candidate.position,
          size: candidate.size,
          confidence: (confSum / hits).clamp(0.0, 1.0),
        ));
      }
    }
    return result;
  }

  // Pulls out normalized luma (and, where cheaply available, chroma) samples
  // from a raw camera frame, on a downsampled grid, handling both formats
  // the camera plugin actually delivers: yuv420 (Android) and bgra8888 (iOS).
  _FrameSamples? _extractFrameSamples(CameraImage image) {
    const int gridStep = 12; // sample every 12th pixel — plenty for blob-scale detection, and fast

    final width = image.width;
    final height = image.height;
    final cols = (width / gridStep).floor();
    final rows = (height / gridStep).floor();
    if (cols < 3 || rows < 3) return null;

    final luma = Float32List(cols * rows);
    final isNeutral = List<bool>.filled(cols * rows, false);

    if (image.format.group == ImageFormatGroup.yuv420 && image.planes.isNotEmpty) {
      final yPlane = image.planes[0];
      final yBytes = yPlane.bytes;
      final yStride = yPlane.bytesPerRow;
      final yPixelStride = yPlane.bytesPerPixel ?? 1;

      Uint8List? uBytes, vBytes;
      int uStride = 0, uPixelStride = 1, vStride = 0, vPixelStride = 1;
      if (image.planes.length >= 3) {
        uBytes = image.planes[1].bytes;
        uStride = image.planes[1].bytesPerRow;
        uPixelStride = image.planes[1].bytesPerPixel ?? 1;
        vBytes = image.planes[2].bytes;
        vStride = image.planes[2].bytesPerRow;
        vPixelStride = image.planes[2].bytesPerPixel ?? 1;
      }

      for (int gy = 0; gy < rows; gy++) {
        final py = gy * gridStep;
        for (int gx = 0; gx < cols; gx++) {
          final px = gx * gridStep;
          final yIndex = py * yStride + px * yPixelStride;
          if (yIndex >= yBytes.length) continue;
          final y = yBytes[yIndex].toDouble();
          luma[gy * cols + gx] = y;

          if (uBytes != null && vBytes != null) {
            final cy = py ~/ 2;
            final cx = px ~/ 2;
            final uIndex = cy * uStride + cx * uPixelStride;
            final vIndex = cy * vStride + cx * vPixelStride;
            if (uIndex < uBytes.length && vIndex < vBytes.length) {
              final u = uBytes[uIndex];
              final v = vBytes[vIndex];
              // U/V near 128 (neutral chroma) means the pixel is close to
              // gray/white rather than strongly colored — used for the
              // "is this a neutral specular glint, not a colored light"
              // check in the flashlight-glint pass.
              isNeutral[gy * cols + gx] = (u - 128).abs() < 12 && (v - 128).abs() < 12;
            }
          }
        }
      }
    } else {
      // bgra8888 (iOS default streaming format): single plane, 4 bytes/pixel.
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final stride = plane.bytesPerRow;
      const bytesPerPixel = 4;

      for (int gy = 0; gy < rows; gy++) {
        final py = gy * gridStep;
        for (int gx = 0; gx < cols; gx++) {
          final px = gx * gridStep;
          final index = py * stride + px * bytesPerPixel;
          if (index + 2 >= bytes.length) continue;
          final b = bytes[index].toDouble();
          final g = bytes[index + 1].toDouble();
          final r = bytes[index + 2].toDouble();
          luma[gy * cols + gx] = 0.299 * r + 0.587 * g + 0.114 * b;
          final maxC = max(r, max(g, b));
          final minC = min(r, min(g, b));
          isNeutral[gy * cols + gx] = (maxC - minC) < 24; // low saturation ~= neutral
        }
      }
    }

    return _FrameSamples(cols: cols, rows: rows, luma: luma, isNeutral: isNeutral);
  }

  // Pass 1: look for small, isolated regions that are much brighter than
  // their immediate surroundings — the signature of a point IR source
  // rather than a broad light source like a window or lamp.
  List<_Spike> _findSpotSpikes(_FrameSamples s) {
    final spikes = <_Spike>[];
    final sensitivityBoost = _sensitivity * 40; // 0-40
    // Dark rooms make any real emitter stand out more starkly, so we can
    // demand a bigger relative jump before calling it a spike; well-lit
    // rooms need a lower relative bar but a higher absolute floor so normal
    // room brightness doesn't trigger constantly.
    final relativeJumpNeeded = _darkRoom ? 35 + sensitivityBoost : 55 + sensitivityBoost;
    final absoluteFloor = _darkRoom ? 40.0 : 140.0;

    for (int y = 1; y < s.rows - 1; y++) {
      for (int x = 1; x < s.cols - 1; x++) {
        final idx = y * s.cols + x;
        final v = s.luma[idx];
        if (v < absoluteFloor) continue;

        double neighborSum = 0;
        int neighborCount = 0;
        for (int dy = -2; dy <= 2; dy++) {
          for (int dx = -2; dx <= 2; dx++) {
            if (dx == 0 && dy == 0) continue;
            final ny = y + dy, nx = x + dx;
            if (ny < 0 || ny >= s.rows || nx < 0 || nx >= s.cols) continue;
            neighborSum += s.luma[ny * s.cols + nx];
            neighborCount++;
          }
        }
        if (neighborCount == 0) continue;
        final neighborAvg = neighborSum / neighborCount;
        final jump = v - neighborAvg;

        if (jump >= relativeJumpNeeded) {
          final confidence = (jump / 200).clamp(0.0, 1.0);
          spikes.add(_Spike(
            position: Offset(x / s.cols, y / s.rows),
            size: (v / 255) * 20 + 6,
            confidence: confidence,
          ));
        }
      }
    }
    return _mergeNearby(spikes);
  }

  // Pass 2: flashlight-assisted lens glint. Real lenses throw back a tiny,
  // very bright, near-colorless highlight when lit directly — distinct from
  // pass 1 in that it doesn't care about IR at all, just "small + blown-out
  // + neutral colored".
  List<_Spike> _findGlintSpikes(_FrameSamples s) {
    final spikes = <_Spike>[];
    for (int y = 0; y < s.rows; y++) {
      for (int x = 0; x < s.cols; x++) {
        final idx = y * s.cols + x;
        final v = s.luma[idx];
        if (v > 235 && s.isNeutral[idx]) {
          spikes.add(_Spike(
            position: Offset(x / s.cols, y / s.rows),
            size: 8,
            confidence: 0.5 + (v - 235) / 40,
          ));
        }
      }
    }
    return _mergeNearby(spikes).where((s) => s.confidence > 0.3).toList();
  }

  List<_Spike> _mergeNearby(List<_Spike> spikes) {
    if (spikes.isEmpty) return [];
    final sorted = List<_Spike>.from(spikes)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final merged = <_Spike>[];
    for (final spike in sorted) {
      var wasMerged = false;
      for (int i = 0; i < merged.length; i++) {
        if ((spike.position - merged[i].position).distance < 0.06) {
          merged[i] = _Spike(
            position: Offset(
              (merged[i].position.dx + spike.position.dx) / 2,
              (merged[i].position.dy + spike.position.dy) / 2,
            ),
            size: max(merged[i].size, spike.size),
            confidence: max(merged[i].confidence, spike.confidence),
          );
          wasMerged = true;
          break;
        }
      }
      if (!wasMerged) merged.add(spike);
    }
    return merged;
  }

  // Fallback ONLY used when the real camera can't be initialized at all
  // (denied permission, no hardware, plugin failure). The UI banner tied to
  // _isSimulated makes this visible to the user at all times — it is never
  // presented as if it were a live reading.
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
          _lastDetected = 'IR SPIKE DETECTED (SIMULATED)';
        } else {
          _irConfidence = max(0, _irConfidence - random.nextDouble() * 10);
          _isAlert = _irConfidence > 60;
          if (!_isAlert) {
            _lastDetected = 'MONITORING (SIMULATED)';
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
    return GestureDetector(
      onTap: _initializeCamera,
      child: Container(
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
                  _isSimulated ? Icons.warning_amber_rounded : Icons.camera_alt_outlined,
                  size: 50,
                  color: _isSimulated
                      ? const Color(0xFFFFB800).withOpacity(0.8)
                      : Colors.white.withOpacity(0.3),
                ),
                const SizedBox(height: 10),
                Text(
                  _isSimulated
                      ? 'CAMERA UNAVAILABLE\nShowing simulated data — not a real scan\nTap to retry'
                      : 'Camera not available\nTap to retry',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: _isSimulated ? FontWeight.w700 : FontWeight.normal,
                    color: _isSimulated
                        ? const Color(0xFFFFB800)
                        : Colors.white.withOpacity(0.3),
                  ),
                ),
              ],
            ),
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

/// Internal candidate spike found in a single frame, before temporal
/// persistence filtering is applied.
class _Spike {
  final Offset position; // normalized 0-1
  final double size;
  final double confidence;

  _Spike({required this.position, required this.size, required this.confidence});
}

/// Downsampled luma (+coarse neutrality) grid extracted from one camera
/// frame, in whatever raw format the platform delivered.
class _FrameSamples {
  final int cols;
  final int rows;
  final Float32List luma;
  final List<bool> isNeutral;

  _FrameSamples({
    required this.cols,
    required this.rows,
    required this.luma,
    required this.isNeutral,
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