// lib/screens/index_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../services/trip_telemetry_service.dart';
import 'conductor_dashboard_screen.dart';
import 'route_survey_screen.dart';

class IndexScreen extends StatefulWidget {
  const IndexScreen({super.key});

  @override
  State<IndexScreen> createState() => _IndexScreenState();
}

class _IndexScreenState extends State<IndexScreen> {
  final TextEditingController _idController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _handleStartDuty() async {
    final rawId = _idController.text.trim();
    if (rawId.isEmpty) {
      _showDialog("Conductor ID Required", "Please enter your assigned Conductor ID.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showDialog("Location Disabled", "Please turn on device GPS to broadcast bus coordinates.");
        setState(() => _isLoading = false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showDialog("Permission Required", "GPS permission is required to broadcast live transit coordinates.");
          setState(() => _isLoading = false);
          return;
        }
      }

      final response = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/conductors/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'callSign': rawId}),
      ).timeout(const Duration(seconds: 8));

      final data = json.decode(response.body);

      setState(() => _isLoading = false);

      if (response.statusCode == 200 && data['success'] == true) {
        final confirmedCallSign = data['callSign'];
        final activeTrip = data['activeTrip'];

        if (data['token'] != null) {
          await TripTelemetryService.instance.setAuthToken(data['token'].toString());
        }

        if (mounted) {
          if (activeTrip != null && activeTrip['corridorId'] != null) {
            final resumedCorridorId = activeTrip['corridorId'].toString();
            await TripTelemetryService.instance.startTrip(
              callSign: confirmedCallSign,
              corridorId: resumedCorridorId,
              corridorName: resumedCorridorId,
              initialStops: const [],
            );

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Resuming active shift on $resumedCorridorId..."),
                backgroundColor: const Color(0xFF1565C0),
                duration: const Duration(seconds: 2),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Welcome ${data['fullName']} ($confirmedCallSign)"),
                backgroundColor: const Color(0xFF2E7D32),
                duration: const Duration(seconds: 2),
              ),
            );
          }

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => ConductorDashboardScreen(callSign: confirmedCallSign),
            ),
          );
        }
      } else {
        _showDialog("Authentication Failed", data['error'] ?? "Conductor ID not found.");
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showDialog("Connection Error", "Cannot reach transit server. Ensure backend is running.");
    }
  }

  void _showDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: Text(message, style: const TextStyle(fontSize: 15)),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBFBFB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),

                  // Red Bus Brand Image
                  Container(
                    height: 170,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 15,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.asset(
                        'assets/images/red_bus.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Kannada Title
                  const Text(
                    "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF212121),
                      letterSpacing: 0.5,
                    ),
                  ),

                  const SizedBox(height: 36),

                  // Conductor Login Card
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.black26, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 12,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          "Conductor Login",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF212121),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),

                        TextField(
                          controller: _idController,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(
                            labelText: "Enter Conductor ID",
                            prefixIcon: const Icon(Icons.badge_outlined, color: Color(0xFFC62828)),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFC62828), width: 1.8),
                            ),
                          ),
                        ),

                        const SizedBox(height: 22),

                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFC62828),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              elevation: 1,
                            ),
                            onPressed: _isLoading ? null : _handleStartDuty,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                  )
                                : const Text(
                                    "Start Duty",
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Temporary Field Survey Shortcut (Remove after route mapping is complete)
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2E7D32),
                        side: const BorderSide(color: Color(0xFF2E7D32), width: 1.4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RouteSurveyScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_road_rounded, size: 20),
                      label: const Text(
                        "Offline Route Mapper (Field Survey)",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}