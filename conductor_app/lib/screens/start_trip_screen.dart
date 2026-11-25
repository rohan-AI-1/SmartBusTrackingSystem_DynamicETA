// lib/screens/start_trip_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

class StartTripScreen extends StatefulWidget {
  final String callSign;

  const StartTripScreen({super.key, required this.callSign});

  @override
  State<StartTripScreen> createState() => _StartTripScreenState();
}

class _StartTripScreenState extends State<StartTripScreen> {
  List<dynamic> _corridors = [];
  bool _isLoadingCorridors = true;
  String? _selectedRouteId;

  @override
  void initState() {
    super.initState();
    _selectedRouteId = null;
    _fetchCorridorsFromBackend();
  }

  Future<void> _fetchCorridorsFromBackend() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/corridors'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final list = data['corridors'] as List? ?? [];
        if (mounted) {
          setState(() {
            _corridors = list;
            _isLoadingCorridors = false;
          });
        }
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoadingCorridors = false);
    }
  }

  void _handleStartTrip() {
    if (_selectedRouteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Please select a route first!"),
          backgroundColor: Color(0xFFC62828),
        ),
      );
      return;
    }

    final chosen = _corridors.firstWhere((c) => c['corridorId'] == _selectedRouteId);

    Navigator.of(context).pop({
      'id': chosen['corridorId'],
      'name': chosen['corridorName'],
      'stops': List<String>.from(chosen['stops'] ?? []),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBFBFB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          "Start Trip",
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 28.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black26, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      height: 100,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/images/red_bus.png', fit: BoxFit.contain),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF212121),
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (_isLoadingCorridors)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14.0),
                        child: CircularProgressIndicator(color: Color(0xFFC62828)),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.black87, width: 1.4),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedRouteId,
                            hint: const Text(
                              "Select Route",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black54,
                              ),
                            ),
                            icon: const Icon(Icons.arrow_drop_down, color: Colors.black87, size: 28),
                            items: _corridors.map((route) {
                              return DropdownMenuItem<String>(
                                value: route["corridorId"]?.toString(),
                                child: Text(
                                  route["corridorName"]?.toString() ?? "",
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF212121),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() => _selectedRouteId = value);
                            },
                          ),
                        ),
                      ),
                    const SizedBox(height: 30),
                    Container(
                      width: 150,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFC62828), width: 1.6),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFC62828).withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFFC62828),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onPressed: _handleStartTrip,
                        child: const Text(
                          "Start trip",
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}