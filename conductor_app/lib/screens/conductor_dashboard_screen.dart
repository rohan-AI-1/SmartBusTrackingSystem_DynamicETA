// lib/screens/conductor_dashboard_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../services/trip_telemetry_service.dart';
import 'index_screen.dart';
import 'start_trip_screen.dart';
import 'change_trip_screen.dart';
import 'conductor_announcements_screen.dart';
import 'live_trip_screen.dart';
import 'route_survey_screen.dart';

class ConductorDashboardScreen extends StatefulWidget {
  final String callSign;

  const ConductorDashboardScreen({super.key, required this.callSign});

  @override
  State<ConductorDashboardScreen> createState() => _ConductorDashboardScreenState();
}

class _ConductorDashboardScreenState extends State<ConductorDashboardScreen> {
  final TripTelemetryService _telemetry = TripTelemetryService.instance;

  @override
  void initState() {
    super.initState();
    _telemetry.addListener(_onTelemetryChanged);
  }

  @override
  void dispose() {
    _telemetry.removeListener(_onTelemetryChanged);
    super.dispose();
  }

  void _onTelemetryChanged() {
    if (mounted) setState(() {});
  }

  // --- 1. Start Trip Action (Starts background GPS immediately!) ---
  void _onStartTrip() async {
    if (_telemetry.isTripActive) {
      _showAlertDialog(
        "Trip In Progress",
        "Already you are in a trip. Stop it to start another.",
      );
      return;
    }

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StartTripScreen(callSign: widget.callSign),
      ),
    );

    if (result != null && result is Map) {
      await _telemetry.startTrip(
        callSign: widget.callSign,
        corridorId: result['id'],
        corridorName: result['name'],
        initialStops: List<String>.from(result['stops'] ?? []),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Live GPS Started: ${result['name']}"),
            backgroundColor: const Color(0xFF2E7D32),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // --- 2. Stop Trip Action ---
  void _onStopTrip() {
    if (!_telemetry.isTripActive) {
      _showAlertDialog("No Active Trip", "No active trip to stop!");
      return;
    }

    _showConfirmationDialog(
      title: "Stop Trip",
      message: "Do you want to stop the current trip?",
      confirmButtonText: "Yes, I confirm",
      onConfirm: () async {
        await _telemetry.stopTrip();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Current trip stopped. Ready for next trip."),
              backgroundColor: Colors.black87,
            ),
          );
        }
      },
    );
  }

  // --- 3. Change Trip Action ---
  void _onChangeTrip() async {
    if (!_telemetry.isTripActive) {
      _showAlertDialog("Trip Notice", "Start a trip first!");
      return;
    }

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChangeTripScreen(
          callSign: widget.callSign,
          currentCorridorId: _telemetry.corridorId,
          currentRouteName: _telemetry.corridorName,
        ),
      ),
    );

    if (result != null && result is Map) {
      await _telemetry.changeRoute(
        newCorridorId: result['id'],
        newCorridorName: result['name'],
        newStops: List<String>.from(result['stops'] ?? []),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Switched Route to: ${result['name']}"),
            backgroundColor: const Color(0xFF2E7D32),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // --- 4. End Duty Action ---
  void _onEndDuty() {
    if (_telemetry.isTripActive) {
      _showAlertDialog(
        "Active Trip in Progress",
        "You have an ongoing active trip. Please stop the current trip before ending duty.",
      );
      return;
    }

    _showConfirmationDialog(
      title: "End Duty Confirmation",
      message: "Do you want to end your duty and log out?",
      confirmButtonText: "Yes, I confirm",
      onConfirm: () {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const IndexScreen()),
          (route) => false,
        );
      },
    );
  }

  void _openTicketVerifierDialog() {
    final codeCtrl = TextEditingController();
    String? resultBanner;
    bool isValidResult = false;
    bool isChecking = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.verified_user_rounded, color: Color(0xFF2E7D32), size: 24),
              SizedBox(width: 8),
              Text("Verify Ticket / Pass", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: "6-Char Ticket Code or STU-VJP-...",
                  hintText: "e.g., A4F91C or STU-VJP-4021",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              if (resultBanner != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isValidResult ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isValidResult ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                    ),
                  ),
                  child: Text(
                    resultBanner!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: isValidResult ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("Close")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
              onPressed: isChecking
                  ? null
                  : () async {
                      final code = codeCtrl.text.trim();
                      if (code.isEmpty) return;
                      setModalState(() => isChecking = true);
                      try {
                        final token = await _telemetry.getAuthToken();
                        final resp = await http.post(
                          Uri.parse('${AppConfig.backendUrl}/api/tickets/verify'),
                          headers: {
                            'Content-Type': 'application/json',
                            if (token != null) 'Authorization': 'Bearer $token',
                          },
                          body: json.encode({
                            'callSign': widget.callSign,
                            'codeOrPassId': code,
                          }),
                        );
                        final data = json.decode(resp.body);
                        setModalState(() {
                          isChecking = false;
                          isValidResult = resp.statusCode == 200 && data['valid'] == true;
                          resultBanner = isValidResult
                              ? "VALID: ${data['message']}"
                              : "INVALID: ${data['error'] ?? 'Verification failed'}";
                        });
                      } catch (_) {
                        setModalState(() {
                          isChecking = false;
                          isValidResult = false;
                          resultBanner = "Network error verifying ticket.";
                        });
                      }
                    },
              child: const Text("Verify Now", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _openProfileDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Row(
          children: [
            Icon(Icons.badge_rounded, color: Color(0xFFC62828), size: 26),
            SizedBox(width: 8),
            Text("Conductor Profile", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.directions_bus_rounded, color: Color(0xFFC62828)),
              title: const Text("Assigned Bus ID", style: TextStyle(fontSize: 12, color: Colors.black54)),
              subtitle: Text(widget.callSign, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_balance_rounded, color: Color(0xFF2E7D32)),
              title: const Text("Division", style: TextStyle(fontSize: 12, color: Colors.black54)),
              subtitle: const Text("KKRTC Vijayapura City", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sensors_rounded, color: Color(0xFF00796B)),
              title: const Text("Duty Status", style: TextStyle(fontSize: 12, color: Colors.black54)),
              subtitle: Text(
                _telemetry.isTripActive ? "Active Trip (${_telemetry.corridorName ?? ''})" : "On Duty — Standby",
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Close", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAlertDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFFC62828))),
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

  void _showConfirmationDialog({
    required String title,
    required String message,
    required String confirmButtonText,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: Text(message, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("Cancel", style: TextStyle(color: Colors.black54, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            onPressed: () {
              Navigator.of(ctx).pop();
              onConfirm();
            },
            child: Text(confirmButtonText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
        iconTheme: const IconThemeData(color: Colors.black87, size: 28),
      ),
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFFC62828),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: Colors.white,
                      child: Icon(Icons.directions_bus_filled_rounded, color: Color(0xFFC62828), size: 30),
                    ),
                    SizedBox(height: 12),
                    Text(
                      "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.person_outline_rounded, color: Color(0xFFC62828)),
                title: const Text("Profile", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Bus ID, division & duty status", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  _openProfileDialog();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.campaign_rounded, color: Color(0xFFC62828)),
                title: const Text("Announcements", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Broadcast & manage alerts", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ConductorAnnouncementsScreen(callSign: widget.callSign),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add_road_rounded, color: Color(0xFF2E7D32)),
                title: const Text("Route Mapper", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Record real GPS stops & road curves", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RouteSurveyScreen()),
                  );
                },
              ),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                height: 150,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset('assets/images/red_bus.png', fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF212121),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 30),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.45,
                children: [
                  _buildCompactCard(
                    title: "Start Trip",
                    icon: Icons.play_arrow_rounded,
                    color: const Color(0xFFC62828),
                    onTap: _onStartTrip,
                  ),
                  _buildCompactCard(
                    title: "Stop Trip",
                    icon: Icons.stop_rounded,
                    color: Colors.black87,
                    onTap: _onStopTrip,
                  ),
                  _buildCompactCard(
                    title: "Change Trip",
                    icon: Icons.sync_alt_rounded,
                    color: Colors.black87,
                    onTap: _onChangeTrip,
                  ),
                  _buildCompactCard(
                    title: "End Duty",
                    icon: Icons.power_settings_new_rounded,
                    color: const Color(0xFFC62828),
                    onTap: _onEndDuty,
                  ),
                ],
              ),

              // Active Trip Banner + Crowd Occupancy Selector
              if (_telemetry.isTripActive) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 18.0),
                  child: InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const LiveTripScreen(),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2E7D32)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.sensors_rounded, color: Color(0xFF2E7D32), size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "LIVE: ${_telemetry.corridorName ?? 'Active Route'} (Tap to view)",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2E7D32),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF2E7D32)),
                        ],
                      ),
                    ),
                  ),
                ),

                // One-Tap Bus Crowd Status Bar
                Padding(
                  padding: const EdgeInsets.only(top: 12.0),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCrowdChip("SEATS", "Seats Free", const Color(0xFF2E7D32)),
                        _buildCrowdChip("STANDING", "Standing", const Color(0xFFE65100)),
                        _buildCrowdChip("FULL", "Bus Full", const Color(0xFFC62828)),
                      ],
                    ),
                  ),
                ),

                // Rush-Hour Ticket & Student Pass Verifier Button
                Padding(
                  padding: const EdgeInsets.only(top: 10.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1B5E20),
                        side: const BorderSide(color: Color(0xFF2E7D32), width: 1.3),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _openTicketVerifierDialog,
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                      label: const Text(
                        "Verify Digital Ticket / Student Pass",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCrowdChip(String code, String label, Color color) {
    final bool selected = _telemetry.crowdLevel == code;
    return InkWell(
      onTap: () => _telemetry.updateCrowdLevel(code),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: selected ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  Widget _buildCompactCard({
    required String title,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 3)),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.08), shape: BoxShape.circle),
                child: Icon(icon, size: 28, color: color),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}