import 'package:flutter/material.dart';
import 'screens/registration_index_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ConductorRegistrationApp());
}

class ConductorRegistrationApp extends StatelessWidget {
  const ConductorRegistrationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conductor Registration',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC62828)),
        useMaterial3: true,
      ),
      home: const RegistrationIndexScreen(),
    );
  }
}