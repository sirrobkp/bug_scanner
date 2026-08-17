import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bug Scanner',
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: GoogleFonts.jetBrainsMono().fontFamily,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: const App(),
      debugShowCheckedModeBanner: false,
    );
  }
}