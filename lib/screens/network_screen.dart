import 'package:flutter/material.dart';
import 'dart:math';

class Device {
  final String id;
  final String name;
  final String ip;
  final String mac;
  final String type;
  final int signal;
  final bool threat;
  final String vendor;

  Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.mac,
    required this.type,
    required this.signal,
    required this.threat,
    required this.vendor,
  });
}

class SignalDot extends StatelessWidget {
  final int dbm;

  const SignalDot({super.key, required this.dbm});

  @override
  Widget build(BuildContext context) {
    final pct = max(0.0, min(1.0, (dbm + 100) / 60));
    final color = pct > 0.6
        ? const Color(0xFF00FF66)
        : pct > 0.3
            ? const Color(0xFFFFB800)
            : const Color(0xFFFF2244);

    return SizedBox(
      height: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          final isActive = pct > i * 0.25;
          return Container(
            width: 4,
            height: 4 + i * 3,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: isActive ? color : Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(1),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: color.withOpacity(0.5),
                        blurRadius: 3,
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

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  String? _selectedId;
  double _scanProgress = 100;
  bool _scanning = false;
  int _packetCount = 14872;
  late List<Device> _devices;

  @override
  void initState() {
    super.initState();
    _devices = [
      Device(
        id: '1',
        name: 'ROUTER-MAIN',
        ip: '192.168.1.1',
        mac: 'A4:91:B1:2C:3F:00',
        type: 'Router',
        signal: -38,
        threat: false,
        vendor: 'Cisco',
      ),
      Device(
        id: '2',
        name: 'UNKNOWN_DEV_77',
        ip: '192.168.1.77',
        mac: 'DE:AD:BE:EF:CA:FE',
        type: 'Unknown',
        signal: -62,
        threat: true,
        vendor: '???',
      ),
      Device(
        id: '3',
        name: 'iPhone-ProMax',
        ip: '192.168.1.12',
        mac: 'F8:4D:89:3A:1B:CC',
        type: 'Mobile',
        signal: -44,
        threat: false,
        vendor: 'Apple',
      ),
      Device(
        id: '4',
        name: 'SmartTV-4K',
        ip: '192.168.1.34',
        mac: '00:1A:2B:3C:4D:5E',
        type: 'IoT',
        signal: -71,
        threat: false,
        vendor: 'Samsung',
      ),
      Device(
        id: '5',
        name: 'ESP32_CAM_01',
        ip: '192.168.1.99',
        mac: '24:6F:28:AA:BB:CC',
        type: 'IoT',
        signal: -55,
        threat: true,
        vendor: 'Espressif',
      ),
    ];
    
    _simulatePackets();
  }

  void _simulatePackets() {
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      setState(() {
        _packetCount += Random().nextInt(40);
      });
      _simulatePackets();
    });
  }

  void _startScan() {
    setState(() {
      _scanning = true;
      _scanProgress = 0;
    });
    
    double p = 0;
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 80));
      p += 2 + Random().nextDouble() * 3;
      setState(() {
        _scanProgress = min(100, p);
      });
      return p < 100;
    }).then((_) {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final threats = _devices.where((d) => d.threat).length;

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
                      'MODULE_03',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color.fromRGBO(0, 255, 102, 0.6),
                        letterSpacing: 1.98,
                      ),
                    ),
                    const Text(
                      'NETWORK MAP',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                if (threats > 0)
                  TweenAnimationBuilder(
                    duration: const Duration(milliseconds: 500),
                    tween: Tween<double>(begin: 1, end: 0.5),
                    builder: (context, value, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xFFFF2244),
                          ),
                          borderRadius: BorderRadius.circular(4),
                          color: const Color(0xFFFF2244).withOpacity(0.1),
                        ),
                        child: Text(
                          '$threats THREAT${threats > 1 ? 'S' : ''}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.26,
                            color: Color(0xFFFF2244),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          
          // Stats strip
          Container(
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color.fromRGBO(0, 255, 102, 0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                _buildStatItem('DEVICES', _devices.length.toString(), false),
                _buildStatItem('THREATS', threats.toString(), true),
                _buildStatItem('PACKETS', '${(_packetCount / 1000).toStringAsFixed(1)}K', false),
                _buildStatItem('SSID', '2.4G', false),
              ],
            ),
          ),
          
          // Scan button + progress
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color.fromRGBO(0, 255, 102, 0.06),
                ),
              ),
            ),
            child: _scanning
                ? Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'SCANNING NETWORK...',
                            style: TextStyle(
                              fontSize: 9,
                              color: Color.fromRGBO(0, 255, 102, 0.6),
                              letterSpacing: 1.08,
                            ),
                          ),
                          Text(
                            '${_scanProgress.round()}%',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFF00FF66),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: FractionallySizedBox(
                          widthFactor: _scanProgress / 100,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00FF66), Color.fromRGBO(0, 255, 102, 0.5)],
                              ),
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0xFF00FF66),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _startScan,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF66).withOpacity(0.08),
                        foregroundColor: const Color(0xFF00FF66),
                        side: BorderSide(
                          color: const Color(0xFF00FF66).withOpacity(0.3),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        shadowColor: const Color(0xFF00FF66).withOpacity(0.1),
                        elevation: 2,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                      ),
                      child: const Text(
                        '⟳ RESCAN NETWORK',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                  ),
          ),
          
          // Device list
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                children: _devices.map((device) {
                  final isSelected = _selectedId == device.id;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedId = isSelected ? null : device.id;
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? (device.threat
                                ? const Color(0xFFFF2244).withOpacity(0.08)
                                : const Color(0xFF00FF66).withOpacity(0.06))
                            : const Color(0xFF111111),
                        border: Border.all(
                          color: device.threat
                              ? const Color(0xFFFF2244).withOpacity(0.35)
                              : isSelected
                                  ? const Color(0xFF00FF66).withOpacity(0.35)
                                  : const Color(0xFF00FF66).withOpacity(0.08),
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: device.threat
                            ? [
                                BoxShadow(
                                  color: const Color(0xFFFF2244).withOpacity(0.08),
                                  blurRadius: 10,
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    // Type icon
                                    Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: device.threat
                                            ? const Color(0xFFFF2244).withOpacity(0.12)
                                            : const Color(0xFF00FF66).withOpacity(0.08),
                                        border: Border.all(
                                          color: device.threat
                                              ? const Color(0xFFFF2244).withOpacity(0.3)
                                              : const Color(0xFF00FF66).withOpacity(0.2),
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Center(
                                        child: Text(
                                          device.type == 'Router'
                                              ? '⊕'
                                              : device.type == 'Mobile'
                                                  ? '◈'
                                                  : device.threat
                                                      ? '⚠'
                                                      : '◆',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            device.name,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: device.threat
                                                  ? const Color(0xFFFF2244)
                                                  : Colors.white,
                                              letterSpacing: 0.66,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            '${device.ip} · ${device.vendor}',
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Color.fromRGBO(255, 255, 255, 0.35),
                                              letterSpacing: 0.72,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  SignalDot(dbm: device.signal),
                                  const SizedBox(width: 8),
                                  if (device.threat)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFFFF2244),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0xFFFF2244),
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          
                          // Expanded detail
                          if (isSelected)
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.only(top: 8),
                              decoration: const BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Color.fromRGBO(255, 255, 255, 0.06),
                                  ),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildDetailItem('MAC ADDRESS', device.mac, false),
                                      ),
                                      Expanded(
                                        child: _buildDetailItem('SIGNAL', '${device.signal} dBm', false),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildDetailItem('TYPE', device.type, false),
                                      ),
                                      Expanded(
                                        child: _buildDetailItem(
                                          'STATUS',
                                          device.threat ? 'SUSPICIOUS' : 'TRUSTED',
                                          true,
                                          threat: device.threat,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (device.threat)
                                    Container(
                                      margin: const EdgeInsets.only(top: 6),
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF2244).withOpacity(0.08),
                                        border: Border.all(
                                          color: const Color(0xFFFF2244).withOpacity(0.2),
                                        ),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: const Text(
                                        '⚠ Unrecognised device — possible rogue AP or hidden sensor. Consider blocking.',
                                        style: TextStyle(
                                          fontSize: 8,
                                          color: Color(0xFFFF2244),
                                          height: 1.4,
                                          letterSpacing: 0.48,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, bool isDanger) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: const Color(0xFF00FF66).withOpacity(0.06),
            ),
          ),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 8,
                color: Color.fromRGBO(0, 255, 102, 0.4),
                letterSpacing: 0.96,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDanger ? const Color(0xFFFF2244) : const Color(0xFF00FF66),
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailItem(String label, String value, bool isStatus, {bool threat = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 7,
            color: Color.fromRGBO(0, 255, 102, 0.4),
            letterSpacing: 0.84,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: isStatus
                ? (threat ? const Color(0xFFFF2244) : const Color(0xFF00FF66))
                : Colors.white,
            letterSpacing: 0.54,
          ),
        ),
      ],
    );
  }
}