// lib/main.dart
import 'package:flutter/material.dart';
import 'screens/index_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ConductorApp());
}

class ConductorApp extends StatelessWidget {
  const ConductorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Bus Conductor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD32F2F)),
        useMaterial3: true,
      ),
      home: const IndexScreen(),
    );
  }
}