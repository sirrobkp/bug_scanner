import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../app.dart';

class BottomNav extends StatelessWidget {
  final Screen active;
  final Function(Screen) onNavigate;

  const BottomNav({
    super.key,
    required this.active,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _TabData(
        id: Screen.radar,
        label: 'SCANNER',
        icon: '''
        <svg width="22" height="22" viewBox="0 0 22 22" fill="none">
          <circle cx="11" cy="11" r="9" stroke="currentColor" stroke-width="1.2"/>
          <circle cx="11" cy="11" r="5" stroke="currentColor" stroke-width="1"/>
          <circle cx="11" cy="11" r="1.5" fill="currentColor"/>
          <line x1="11" y1="2" x2="11" y2="5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
          <line x1="11" y1="17" x2="11" y2="20" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
          <line x1="2" y1="11" x2="5" y2="11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
          <line x1="17" y1="11" x2="20" y2="11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
        </svg>
        ''',
      ),
      _TabData(
        id: Screen.camera,
        label: 'CAM DETECT',
        icon: '''
        <svg width="22" height="22" viewBox="0 0 22 22" fill="none">
          <rect x="2" y="5" width="18" height="13" rx="2.5" stroke="currentColor" stroke-width="1.2"/>
          <circle cx="11" cy="11.5" r="3.5" stroke="currentColor" stroke-width="1.2"/>
          <circle cx="11" cy="11.5" r="1.2" fill="currentColor"/>
          <path d="M7 5V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v1" stroke="currentColor" stroke-width="1.2"/>
          <circle cx="17.5" cy="7.5" r="1" fill="currentColor"/>
        </svg>
        ''',
      ),
      _TabData(
        id: Screen.network,
        label: 'NETWORK',
        icon: '''
        <svg width="22" height="22" viewBox="0 0 22 22" fill="none">
          <rect x="9" y="2" width="4" height="4" rx="1" stroke="currentColor" stroke-width="1.1"/>
          <rect x="2" y="16" width="4" height="4" rx="1" stroke="currentColor" stroke-width="1.1"/>
          <rect x="9" y="16" width="4" height="4" rx="1" stroke="currentColor" stroke-width="1.1"/>
          <rect x="16" y="16" width="4" height="4" rx="1" stroke="currentColor" stroke-width="1.1"/>
          <line x1="11" y1="6" x2="11" y2="11" stroke="currentColor" stroke-width="1.1"/>
          <line x1="4" y1="11" x2="18" y2="11" stroke="currentColor" stroke-width="1.1"/>
          <line x1="4" y1="11" x2="4" y2="16" stroke="currentColor" stroke-width="1.1"/>
          <line x1="11" y1="11" x2="11" y2="16" stroke="currentColor" stroke-width="1.1"/>
          <line x1="18" y1="11" x2="18" y2="16" stroke="currentColor" stroke-width="1.1"/>
        </svg>
        ''',
      ),
    ];

    final activeIndex = tabs.indexWhere((t) => t.id == active);
    final tabWidth = 1.0 / tabs.length;

    return Container(
      height: 72,
      color: const Color(0xFF0D0D0D),
      child: Stack(
        children: [
          // Active tab indicator
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            top: 0,
            left: activeIndex * MediaQuery.of(context).size.width * tabWidth,
            width: MediaQuery.of(context).size.width * tabWidth,
            height: 2,
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.transparent, Color(0xFF00FF66), Colors.transparent],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0xFF00FF66),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: tabs.asMap().entries.map((entry) {
              final index = entry.key;
              final tab = entry.value;
              final isActive = active == tab.id;

              return Expanded(
                child: GestureDetector(
                  onTap: () => onNavigate(tab.id),
                  child: Container(
                    height: 72,
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        // Glow background
                        if (isActive)
                          Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0, -0.4),
                                radius: 1.0,
                                colors: [
                                  const Color(0xFF00FF66).withOpacity(0.06),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedScale(
                                scale: isActive ? 1.1 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                child: SvgPicture.string(
                                  tab.icon,
                                  colorFilter: ColorFilter.mode(
                                    isActive
                                        ? const Color(0xFF00FF66)
                                        : Colors.white.withOpacity(0.3),
                                    BlendMode.srcIn,
                                  ),
                                  width: 22,
                                  height: 22,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tab.label,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.96,
                                  color: isActive
                                      ? const Color(0xFF00FF66)
                                      : Colors.white.withOpacity(0.3),
                                  fontFamily: 'JetBrainsMono',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _TabData {
  final Screen id;
  final String label;
  final String icon;

  _TabData({
    required this.id,
    required this.label,
    required this.icon,
  });
}