// lib/main.dart
import 'package:flutter/material.dart';
import 'screens/passenger_search_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PassengerApp());
}

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Bus Passenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC62828)),
        useMaterial3: true,
      ),
      home: const PassengerSearchScreen(),
    );
  }
}