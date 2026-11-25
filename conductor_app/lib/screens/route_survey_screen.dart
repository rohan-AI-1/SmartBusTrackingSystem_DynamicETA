// lib/screens/route_survey_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class RouteSurveyScreen extends StatefulWidget {
  const RouteSurveyScreen({super.key});

  @override
  State<RouteSurveyScreen> createState() => _RouteSurveyScreenState();
}

class _RouteSurveyScreenState extends State<RouteSurveyScreen> {
  static const String _storageKey = 'offline_route_survey_draft_v1';

  final TextEditingController _corridorIdController =
      TextEditingController(text: 'CORRIDOR_1');
  final TextEditingController _corridorNameController =
      TextEditingController();

  bool _isRecording = false;
  bool _isUploading = false;
  Position? _latestPosition;
  StreamSubscription<Position>? _gpsSub;

  List<Map<String, dynamic>> _markedStops = [];
List<Map<String, dynamic>> _breadcrumbs = [];

  @override
  void initState() {
    super.initState();
    _loadDraftFromPhone();
    _primeInitialGps();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _corridorIdController.dispose();
    _corridorNameController.dispose();
    super.dispose();
  }

  Future<void> _primeInitialGps() async {
    try {
      bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      if (mounted) setState(() => _latestPosition = pos);
    } catch (_) {}
  }

  Future<void> _loadDraftFromPhone() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return;

    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _corridorIdController.text =
              decoded['corridorId']?.toString() ?? 'CORRIDOR_1';
          _corridorNameController.text =
              decoded['corridorName']?.toString() ?? '';
          _markedStops = (decoded['stops'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          _breadcrumbs = (decoded['breadcrumbs'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveDraftToPhone() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'corridorId': _corridorIdController.text.trim(),
      'corridorName': _corridorNameController.text.trim(),
      'stops': _markedStops,
      'breadcrumbs': _breadcrumbs,
    };
    await prefs.setString(_storageKey, json.encode(payload));
  }

  Future<void> _startRecording() async {
    if (_corridorIdController.text.trim().isEmpty ||
        _corridorNameController.text.trim().isEmpty) {
      _showMsg("Enter both Corridor ID and Route Name first.", isError: true);
      return;
    }

    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _showMsg("Please turn ON phone GPS / Location first.", isError: true);
      return;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _showMsg("Location permission is required to record route.", isError: true);
      return;
    }

    await _gpsSub?.cancel();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 15, // Automatically capture road curve every 15 meters
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      if (!mounted) return;
      setState(() => _latestPosition = pos);

      // Ignore wild GPS spikes (> 25m inaccuracy)
      if (pos.accuracy > 25.0) return;

      // Record intermediate road curve waypoint only after Stop #1 is marked
      if (_isRecording && _markedStops.isNotEmpty) {
        final int currentSegmentIndex = _markedStops.length - 1;
        _breadcrumbs.add({
          'afterStopIndex': currentSegmentIndex,
          'lat': double.parse(pos.latitude.toStringAsFixed(6)),
          'lng': double.parse(pos.longitude.toStringAsFixed(6)),
        });
        _saveDraftToPhone();
      }
    });

    setState(() => _isRecording = true);
    _saveDraftToPhone();
    _showMsg("Recording started! Tap 'Mark Bus Stop' at each stop.");
  }

  Future<void> _stopRecording() async {
    await _gpsSub?.cancel();
    _gpsSub = null;
    setState(() => _isRecording = false);
    await _saveDraftToPhone();
    _showMsg("Recording paused. Data saved safely on phone.");
  }

  Future<void> _markBusStopHere() async {
    Position? pos = _latestPosition;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      ).timeout(const Duration(seconds: 4));
      if (mounted) setState(() => _latestPosition = pos);
    } catch (_) {}

    if (pos == null) {
      _showMsg("Waiting for GPS satellite lock... Try again in 3 seconds.",
          isError: true);
      return;
    }

    final stopNameController = TextEditingController();
    final int stopNumber = _markedStops.length + 1;

    if (!mounted) return;
    final String? enteredName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          "Mark Stop #$stopNumber",
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "GPS: ${pos!.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)} (±${pos.accuracy.toStringAsFixed(0)}m)",
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: stopNameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: "Bus Stop Name",
                hintText: "e.g., Shivaji Circle",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text("Cancel", style: TextStyle(color: Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
            onPressed: () {
              final text = stopNameController.text.trim();
              if (text.isEmpty) return;
              Navigator.of(ctx).pop(text);
            },
            child: const Text("Save Stop",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (enteredName == null || enteredName.isEmpty) return;

    setState(() {
      _markedStops.add({
        'name': enteredName,
        'lat': double.parse(pos!.latitude.toStringAsFixed(6)),
        'lng': double.parse(pos.longitude.toStringAsFixed(6)),
      });
    });

    await _saveDraftToPhone();
    _showMsg("Saved Stop #$stopNumber: $enteredName");
  }

  Future<void> _editOrDeleteStop(int index) async {
    final item = _markedStops[index];
    final controller = TextEditingController(text: item['name']?.toString() ?? '');

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text("Edit Stop #${index + 1}",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: "Stop Name",
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('DELETE'),
            child: const Text("Delete",
                style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('CANCEL'),
            child: const Text("Cancel", style: TextStyle(color: Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
            onPressed: () => Navigator.of(ctx).pop('SAVE'),
            child: const Text("Save", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (action == 'DELETE') {
      setState(() => _markedStops.removeAt(index));
      await _saveDraftToPhone();
    } else if (action == 'SAVE' && controller.text.trim().isNotEmpty) {
      setState(() => _markedStops[index]['name'] = controller.text.trim());
      await _saveDraftToPhone();
    }
  }

  Future<void> _uploadSurveyToBackend() async {
    if (_markedStops.length < 2) {
      _showMsg("Mark at least 2 stops (Origin & Destination) before uploading.",
          isError: true);
      return;
    }

    setState(() => _isUploading = true);
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/admin/import-survey'),
            headers: {
              'Content-Type': 'application/json',
              'x-admin-key': 'KKRTC_VJP_ADMIN_2026',
            },
            body: json.encode({
              'corridorId': _corridorIdController.text.trim(),
              'corridorName': _corridorNameController.text.trim(),
              'stops': _markedStops,
              'breadcrumbs': _breadcrumbs,
            }),
          )
          .timeout(const Duration(seconds: 12));

      final data = json.decode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        _showMsg(
          "Uploaded! ${data['stopsSaved']} stops & ${data['waypointsSaved']} road waypoints saved to Cloud.",
        );
      } else {
        _showMsg(data['error']?.toString() ?? "Upload failed.", isError: true);
      }
    } catch (e) {
      _showMsg(
        "Could not reach server. Make sure laptop server is running on same Wi-Fi.",
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _copyJsonBackup() async {
    final jsonString = const JsonEncoder.withIndent('  ').convert({
      'corridorId': _corridorIdController.text.trim(),
      'corridorName': _corridorNameController.text.trim(),
      'stops': _markedStops,
      'breadcrumbs': _breadcrumbs,
    });
    await Clipboard.setData(ClipboardData(text: jsonString));
    _showMsg("Survey JSON copied to clipboard!");
  }

  Future<void> _clearDraft() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Clear Recorded Survey?"),
        content: const Text("This will erase the current draft stored on your phone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Clear",
                style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await _gpsSub?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    if (mounted) {
      setState(() {
        _isRecording = false;
        _markedStops = [];
        _breadcrumbs = [];
      });
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String gpsLabel = _latestPosition == null
        ? "Acquiring GPS..."
        : "${_latestPosition!.latitude.toStringAsFixed(5)}, ${_latestPosition!.longitude.toStringAsFixed(5)} (±${_latestPosition!.accuracy.toStringAsFixed(0)}m)";

    return Scaffold(
      backgroundColor: const Color(0xFFFBFBFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          "Route Survey Recorder",
          style: TextStyle(color: Color(0xFF212121), fontWeight: FontWeight.bold, fontSize: 17),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded, color: Colors.black87),
            tooltip: "Copy JSON backup",
            onPressed: _copyJsonBackup,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFC62828)),
            tooltip: "Clear draft",
            onPressed: _clearDraft,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // GPS Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _latestPosition != null
                      ? const Color(0xFF2E7D32).withValues(alpha: 0.1)
                      : const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _latestPosition != null
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFE65100),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.gps_fixed_rounded,
                      size: 18,
                      color: _latestPosition != null
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFE65100),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        gpsLabel,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                    ),
                    Text(
                      "${_breadcrumbs.length} curves",
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.black54),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Route ID & Route Name Inputs
              Row(
                children: [
                  SizedBox(
                    width: 125,
                    child: TextField(
                      controller: _corridorIdController,
                      enabled: !_isRecording,
                      decoration: InputDecoration(
                        labelText: "Route ID",
                        hintText: "CORRIDOR_1",
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _corridorNameController,
                      enabled: !_isRecording,
                      decoration: InputDecoration(
                        labelText: "Route Name",
                        hintText: "Central Stand - Torvi",
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Start / Pause Recording & Big "Mark Bus Stop" Action Buttons
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isRecording
                              ? const Color(0xFFE65100)
                              : const Color(0xFF212121),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isRecording ? _stopRecording : _startRecording,
                        icon: Icon(_isRecording
                            ? Icons.pause_circle_filled_rounded
                            : Icons.fiber_manual_record_rounded),
                        label: Text(
                          _isRecording ? "Pause" : "Start Survey",
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _markBusStopHere,
                        icon: const Icon(Icons.add_location_alt_rounded, size: 22),
                        label: const Text(
                          "Mark Bus Stop Here",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              Text(
                "Recorded Stops (${_markedStops.length})",
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
              ),
              const SizedBox(height: 8),

              // List of Recorded Stops
              Expanded(
                child: _markedStops.isEmpty
                    ? Center(
                        child: Text(
                          "Park at Origin Terminal, tap 'Start Survey', then tap 'Mark Bus Stop Here' at each stop.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _markedStops.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (ctx, idx) {
                          final s = _markedStops[idx];
                          return ListTile(
                            tileColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: const BorderSide(color: Colors.black12),
                            ),
                            leading: CircleAvatar(
                              radius: 15,
                              backgroundColor: const Color(0xFFC62828),
                              child: Text(
                                "${idx + 1}",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            title: Text(
                              s['name']?.toString() ?? '',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            subtitle: Text(
                              "${s['lat']}, ${s['lng']}",
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _editOrDeleteStop(idx),
                            ),
                          );
                        },
                      ),
              ),

              const SizedBox(height: 10),

              // Upload Button (Use when back home on Wi-Fi)
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC62828),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _isUploading ? null : _uploadSurveyToBackend,
                  icon: _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_rounded),
                  label: Text(
                    _isUploading ? "Uploading..." : "Upload Route to Backend",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}