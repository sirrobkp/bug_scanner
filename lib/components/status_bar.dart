import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:async';

class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  String _time = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateTime() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    setState(() {
      _time = '$hour:$minute';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: const Color(0xFF0D0D0D),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _time,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: 0.65,
            ),
          ),
          Row(
            children: [
              // Signal bars
              SizedBox(
                height: 12,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [4, 6, 8, 10, 12].asMap().entries.map((entry) {
                    final height = entry.value;
                    final index = entry.key;
                    return Container(
                      width: 3,
                      height: height.toDouble(),
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: index < 4
                            ? const Color(0xFF00FF66)
                            : Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(width: 6),
              // WiFi icon
              SizedBox(
                width: 16,
                height: 12,
                child: SvgPicture.string(
                  '''
                  <svg viewBox="0 0 16 12" fill="none">
                    <path d="M8 10a1 1 0 1 1 0 2 1 1 0 0 1 0-2z" fill="#00FF66"/>
                    <path d="M4.5 7.5C5.6 6.4 6.7 5.8 8 5.8s2.4.6 3.5 1.7" stroke="#00FF66" stroke-width="1.2" stroke-linecap="round" fill="none"/>
                    <path d="M2 5C3.8 3.2 5.8 2.2 8 2.2s4.2 1 6 2.8" stroke="rgba(0,255,102,0.4)" stroke-width="1.2" stroke-linecap="round" fill="none"/>
                  </svg>
                  ''',
                  colorFilter: const ColorFilter.mode(Color(0xFF00FF66), BlendMode.srcIn),
                ),
              ),
              const SizedBox(width: 6),
              // Battery
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 12,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white.withOpacity(0.35)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00FF66),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                  Container(
                    width: 2,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.3),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(1),
                        bottomRight: Radius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}