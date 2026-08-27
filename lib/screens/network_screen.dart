import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

// NOTE ON WHAT A PHONE CAN ACTUALLY DISCOVER ON A LAN:
// - There is no cross-platform "list nearby WiFi networks/SSIDs" API for
//   ordinary apps. iOS in particular does not allow third-party apps to scan
//   nearby access points at all. What we CAN do — and what this screen now
//   does — is discover devices on the LAN you're already connected to, by
//   sweeping the /24 subnet with TCP connection attempts.
// - Real ICMP ping isn't available from Dart without native/root code, so
//   "is this host alive" is inferred from TCP behavior on a handful of
//   common ports (an open port, or even an actively refused connection,
//   proves the host exists; a timeout is inconclusive, not proof of
//   absence). Quiet hosts that don't answer any probed port can be missed —
//   that's an inherent limit of a portable, non-root scan, not a bug.
// - Per-device MAC addresses are OS-restricted: iOS never exposes them to
//   apps, and modern Android mostly doesn't either. We best-effort read
//   /proc/net/arp on Android (works only for hosts already in the kernel's
//   ARP cache, and only on some devices/OS versions) and are explicit in
//   the UI when we don't have it, rather than showing a fabricated value.
// - "Signal" for OTHER devices' WiFi RSSI is not obtainable by a phone at
//   all (a client only knows its own signal to the access point, never
//   another client's). We repurpose that same bar indicator to show scan
//   response latency instead — a real, measured signal, just a different
//   one — and say so below.
// - Vendor-from-MAC (OUI) lookup uses a small local table of prefixes
//   relevant to common routers/phones and to chipsets often found in cheap
//   IP/hidden cameras (e.g. Espressif, Hi-Silicon/Xiongmai-style DVR
//   boards). It is not exhaustive.

/// Ports commonly exposed by cheap IP cameras / DVR boards. A hit here is a
/// heuristic signal worth a manual look, not proof of a hidden camera —
/// legitimate devices (NAS boxes, printers, routers) sometimes share these.
const Set<int> _cameraTypicalPorts = {554, 8554, 34567, 37777, 9000, 8081};

/// Broader set of ports we probe per host to decide "is this host alive".
const List<int> _probePorts = [
  80, 443, 8080, 8081, 554, 8554, 34567, 37777, 9000, 23, 22, 445, 62078,
];

const Map<String, String> _ouiVendors = {
  '24:6F:28': 'Espressif (ESP32)',
  '30:AE:A4': 'Espressif (ESP32)',
  'EC:FA:BC': 'Espressif (ESP32)',
  '8C:CE:4E': 'Xiongmai/Hi-Silicon DVR chipset',
  '00:12:12': 'Hi-Silicon DVR chipset',
  'A4:91:B1': 'Cisco',
  'F8:4D:89': 'Apple',
  '3C:5A:B4': 'Google',
  '00:1A:2B': 'Samsung',
};

class Device {
  final String id;
  final String name;
  final String ip;
  final String mac;
  final String type;
  final int signal; // bucketed from measured TCP response latency, see note above
  final bool threat;
  final String vendor;
  final List<int> openPorts;
  final String? reason; // why this device was flagged, shown in the detail panel

  Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.mac,
    required this.type,
    required this.signal,
    required this.threat,
    required this.vendor,
    this.openPorts = const [],
    this.reason,
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
  double _scanProgress = 0;
  bool _scanning = false;
  String? _scanError;
  String? _ssid;
  DateTime? _lastScanAt;
  List<Device> _devices = [];

  final Map<String, String> _arpCache = {};

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  /// Best-effort MAC lookup on Android via the kernel ARP cache. Only finds
  /// entries the OS has already talked to; frequently empty on modern
  /// Android builds due to platform sandboxing, and always empty on iOS —
  /// that's a platform restriction, not something fixable from Dart.
  Future<void> _loadArpTable() async {
    _arpCache.clear();
    if (!Platform.isAndroid) return;
    try {
      final file = File('/proc/net/arp');
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      for (final line in lines.skip(1)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 4) {
          final ip = parts[0];
          final mac = parts[3].toUpperCase();
          if (mac != '00:00:00:00:00:00' && mac.contains(':')) {
            _arpCache[ip] = mac;
          }
        }
      }
    } catch (_) {
      // Not readable on this device/OS version — expected in many cases.
    }
  }

  String? _vendorFromMac(String? mac) {
    if (mac == null || mac.length < 8) return null;
    final prefix = mac.substring(0, 8).toUpperCase();
    return _ouiVendors[prefix];
  }

  Future<String?> _resolveSsid(NetworkInfo info) async {
    try {
      if (Platform.isAndroid) {
        // SSID is treated as location-adjacent data pre-Android 13.
        var status = await Permission.locationWhenInUse.status;
        if (!status.isGranted) {
          status = await Permission.locationWhenInUse.request();
        }
        if (!status.isGranted) return null;
      }
      final ssid = await info.getWifiName();
      if (ssid == null) return null;
      return ssid.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }

  int _latencyToSignalBucket(int elapsedMs, {required bool responded}) {
    // Not real RF signal strength (see file header note) — a coarse,
    // real-measurement-based stand-in so the existing bar indicator still
    // means something rather than being random.
    if (!responded) return -85;
    if (elapsedMs < 60) return -35;
    if (elapsedMs < 150) return -50;
    if (elapsedMs < 300) return -65;
    return -78;
  }

  Future<Device?> _probeHost(String ip, {required bool isSelf}) async {
    final openPorts = <int>[];
    bool hostAlive = isSelf;
    final stopwatch = Stopwatch()..start();

    await Future.wait(_probePorts.map((port) async {
      try {
        final socket = await Socket.connect(
          ip,
          port,
          timeout: const Duration(milliseconds: 350),
        );
        hostAlive = true;
        openPorts.add(port);
        await socket.close();
      } on SocketException catch (e) {
        final msg = e.osError?.message.toLowerCase() ?? e.message.toLowerCase();
        if (msg.contains('refused')) {
          // Actively refused means something is there, just not listening
          // on this particular port.
          hostAlive = true;
        }
      } catch (_) {
        // Timeout / unreachable — inconclusive for this port, try the rest.
      }
    }));
    stopwatch.stop();

    if (!hostAlive) return null;

    String? hostname;
    if (!isSelf) {
      try {
        final resolved = await InternetAddress(ip)
            .reverse()
            .timeout(const Duration(milliseconds: 400));
        if (resolved.host.isNotEmpty && resolved.host != ip) {
          hostname = resolved.host;
        }
      } catch (_) {
        // No PTR record / no local mDNS responder — common and not itself
        // suspicious on most home networks.
      }
    }

    final mac = _arpCache[ip];
    final ouiVendor = _vendorFromMac(mac);
    openPorts.sort();
    final looksLikeCameraPort = openPorts.any((p) => _cameraTypicalPorts.contains(p));
    final looksLikeCameraVendor = ouiVendor?.toLowerCase().contains('esp') == true ||
        ouiVendor?.toLowerCase().contains('dvr') == true;

    String? reason;
    final threat = !isSelf && hostname == null && (looksLikeCameraPort || looksLikeCameraVendor);
    if (threat) {
      final bits = <String>[];
      if (hostname == null) bits.add('no resolvable hostname');
      if (looksLikeCameraPort) {
        bits.add('camera-typical port(s) open (${openPorts.where((p) => _cameraTypicalPorts.contains(p)).join(', ')})');
      }
      if (looksLikeCameraVendor) bits.add('MAC vendor matches a common camera-module chipset');
      reason = '${bits.join(' + ')}. Worth a manual look — not confirmed.';
    }

    return Device(
      id: ip,
      name: isSelf ? 'THIS DEVICE' : (hostname ?? 'UNKNOWN_${ip.split('.').last}'),
      ip: ip,
      mac: mac ?? 'Not available (OS-restricted)',
      type: isSelf
          ? 'This Device'
          : (looksLikeCameraPort ? 'Possible Camera' : (openPorts.isEmpty ? 'Unresponsive' : 'Device')),
      signal: _latencyToSignalBucket(stopwatch.elapsedMilliseconds, responded: true),
      threat: threat,
      vendor: ouiVendor ?? (isSelf ? 'This device' : 'Unknown'),
      openPorts: openPorts,
      reason: reason,
    );
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _scanError = null;
    });

    try {
      final info = NetworkInfo();
      await _loadArpTable();
      final ssid = await _resolveSsid(info);
      final wifiIp = await info.getWifiIP();

      if (wifiIp == null || wifiIp.isEmpty) {
        throw Exception('Not connected to a WiFi network');
      }

      final octets = wifiIp.split('.');
      if (octets.length != 4) {
        throw Exception('Unexpected local IP format: $wifiIp');
      }
      final subnetPrefix = '${octets[0]}.${octets[1]}.${octets[2]}';
      final selfLastOctet = int.tryParse(octets[3]) ?? -1;

      const totalHosts = 254;
      const batchSize = 24;
      final found = <Device>[];
      int completed = 0;

      for (int batchStart = 1; batchStart <= totalHosts; batchStart += batchSize) {
        final batchEnd = min(batchStart + batchSize - 1, totalHosts);
        final futures = <Future<Device?>>[];
        for (int i = batchStart; i <= batchEnd; i++) {
          futures.add(_probeHost('$subnetPrefix.$i', isSelf: i == selfLastOctet));
        }
        final results = await Future.wait(futures);
        for (final d in results) {
          if (d != null) found.add(d);
        }
        completed += (batchEnd - batchStart + 1);
        if (mounted) {
          setState(() => _scanProgress = (completed / totalHosts * 100).clamp(0, 100));
        }
      }

      found.sort((a, b) {
        if (a.type == 'This Device') return -1;
        if (b.type == 'This Device') return 1;
        return a.ip.compareTo(b.ip);
      });

      if (mounted) {
        setState(() {
          _devices = found;
          _ssid = ssid;
          _scanning = false;
          _lastScanAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final threats = _devices.where((d) => d.threat).length;
    final openPortsTotal = _devices.fold<int>(0, (sum, d) => sum + d.openPorts.length);

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
                _buildStatItem('OPEN PORTS', openPortsTotal.toString(), false),
                _buildStatItem('SSID', _ssid ?? 'N/A', false),
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
            child: (_devices.isEmpty && !_scanning)
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _scanError != null ? Icons.wifi_off : Icons.search,
                            size: 36,
                            color: Colors.white.withOpacity(0.25),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _scanError != null
                                ? 'Scan failed: $_scanError'
                                : 'No devices found on this network yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.4),
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
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
                                      child: Text(
                                        '⚠ ${device.reason ?? 'Unrecognised device — worth a manual look.'}',
                                        style: const TextStyle(
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