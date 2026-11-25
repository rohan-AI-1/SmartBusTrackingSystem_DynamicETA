// lib/screens/live_road_tracking_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config/app_config.dart';
import '../widgets/asphalt_road_painter.dart';

class LiveRoadTrackingScreen extends StatefulWidget {
  final String callSign;
  final String corridorId;
  final String corridorName;
  final String pickupStop;
  final String destinationStop;
  final int initialEta;
  final String lockedDirection; // Strictly 'FORWARD' or 'RETURN' — never rebounds!
  final List<String> orderedStopNames;
  final int journeyDistanceMeters;

  const LiveRoadTrackingScreen({
    super.key,
    required this.callSign,
    required this.corridorId,
    required this.corridorName,
    required this.pickupStop,
    required this.destinationStop,
    required this.initialEta,
    required this.lockedDirection,
    required this.orderedStopNames,
    required this.journeyDistanceMeters,
  });

  @override
  State<LiveRoadTrackingScreen> createState() => _LiveRoadTrackingScreenState();
}

class _LiveRoadTrackingScreenState extends State<LiveRoadTrackingScreen> {
  io.Socket? _socket;
  StreamSubscription<Position>? _crowdGpsStream;

  bool _isDetourActive = false;
  String _detourPathway = "";
  String _rejoinStop = "";

  bool _isInsideBus = false;
  String _crowdLevel = 'SEATS';
  String _mlAnomalyType = 'NORMAL';
  bool _showProximityOnboardPrompt = false;
  String? _stopSurgeMessage;
  Map<String, dynamic>? _activeDigitalTicket;
  String? _activeStudentPassId;
  bool _isIssuingTicket = false;

  late List<String> _displayedStops;
  int _currentBusIndex = 0;
  double _busProgress = 0.0;
  int _etaMinutes = 1;

  // FSM Dialog One-Shot Guards & Journey Metrics
  bool _hasShownSourceArrivalDialog = false;
  bool _hasShownDestinationDialog = false;
  DateTime? _boardedOrSourceArrivalTime;

  @override
  void initState() {
    super.initState();
    _etaMinutes = widget.initialEta;
    _displayedStops = List<String>.from(widget.orderedStopNames);
    _initLiveSocket();
    _startCrowdsourcedGps();
  }

  void _initLiveSocket() {
    try {
      _socket = io.io(
        AppConfig.backendUrl,
        <String, dynamic>{
          'transports': ['websocket'],
          'autoConnect': true,
          'reconnection': true,
          'reconnectionAttempts': 99999,
          'reconnectionDelay': 1000,
        },
      );

      _socket?.on('bus:telemetry_stream', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) {
          return;
        }

        // DIRECTION LOCK: Ignore telemetry if bus has already rebounded to the opposite direction
        final incomingDirection = data['direction']?.toString().toUpperCase();
        if (incomingDirection != null && incomingDirection != widget.lockedDirection) {
          return;
        }

        setState(() {
          if (_displayedStops.isEmpty && data['orderedStops'] is List) {
            _displayedStops = (data['orderedStops'] as List)
                .map((s) => s['name']?.toString() ?? '')
                .where((n) => n.isNotEmpty)
                .toList();
          }

          final incomingProgress = data['progress'];
          if (incomingProgress is num) {
            _busProgress = incomingProgress.toDouble();
          }

          final incomingIndex = data['currentStopIndex'];
          if (incomingIndex is int) {
            _currentBusIndex = incomingIndex;
          }

          if (data['crowdLevel'] is String) {
            _crowdLevel = data['crowdLevel'];
          }
          if (data['mlAnomalyType'] is String) {
            _mlAnomalyType = data['mlAnomalyType'];
          }

          final targetStop = _isInsideBus ? widget.destinationStop : widget.pickupStop;
          final targetIdx = _displayedStops.indexWhere(
            (stop) => stop.trim().toLowerCase() == targetStop.trim().toLowerCase(),
          );

          if (targetIdx != -1) {
            final stopsAway = targetIdx - _busProgress;
            _etaMinutes = stopsAway > 0.1 ? (stopsAway * 3).ceil() : 0;
          }
        });

        _evaluateFsmArrivalTriggers();
      });

      _socket?.on('bus:detour_alert', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) return;
        final bool active = data['isDetourActive'] == true;
        final String reason = data['reason']?.toString() ?? "Traffic / Event";
        final String pathway = data['pathwayName']?.toString() ?? "";
        final String rejoin = data['rejoinStopName']?.toString() ?? "";
        final List<String> divertedStops = (data['divertedStops'] is List)
            ? (data['divertedStops'] as List).map((e) => e.toString()).toList()
            : [];

        setState(() {
          _isDetourActive = active;
          _detourPathway = pathway;
          _rejoinStop = rejoin;
        });

        if (active) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: const Row(
                children: [
                  Icon(Icons.alt_route_rounded, color: Color(0xFFE65100), size: 26),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Route Diversion Alert",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Color(0xFFE65100)),
                    ),
                  ),
                ],
              ),
              content: Text(
                "Due to traffic ($reason), ${widget.callSign} has changed its route via $pathway.\n\nTap OK to view the diverted route on the road map.",
                style: const TextStyle(fontSize: 14),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE65100)),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    if (divertedStops.isNotEmpty && mounted) {
                      setState(() {
                        _displayedStops = divertedStops;
                        _busProgress = 0.2;
                      });
                    }
                  },
                  child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        } else if (!active && widget.orderedStopNames.isNotEmpty) {
          setState(() {
            _displayedStops = List<String>.from(widget.orderedStopNames);
          });
        }
      });

      _socket?.on('bus:crowd_updated', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) return;
        setState(() => _crowdLevel = data['crowdLevel']?.toString() ?? 'SEATS');
      });

      _socket?.on('bus:ml_anomaly', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) return;
        setState(() {
          _mlAnomalyType = data['anomalyType']?.toString() ?? 'NORMAL';
        });
      });

      _socket?.on('bus:stop_surge', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) return;
        final stopName = data['stopName']?.toString() ?? 'upcoming stop';
        final delayMin = data['extraDelayMin'] ?? 1;
        setState(() {
          _stopSurgeMessage = "Heavy boarding rush at $stopName (+$delayMin min dwell)";
        });
      });

      _socket?.on('passenger:confirm_onboard', (data) {
        if (data is! Map || data['callSign'] != widget.callSign || !mounted) return;
        if (!_isInsideBus) {
          setState(() => _showProximityOnboardPrompt = true);
        }
      });

      _socket?.onConnect((_) {
        _socket?.emit('trip:get_live_state', {'callSign': widget.callSign});
      });
    } catch (e) {
      debugPrint("Socket initialization error: $e");
    }
  }

  /// Triggers FSM Modal 1 (Source Arrival) and FSM Modal 2 (Destination Arrival -> Journey Summary)
  void _evaluateFsmArrivalTriggers() {
    if (!mounted || _displayedStops.isEmpty) return;

    final pickupIdx = _displayedStops.indexWhere(
      (s) => s.trim().toLowerCase() == widget.pickupStop.trim().toLowerCase(),
    );
    final destIdx = _displayedStops.indexWhere(
      (s) => s.trim().toLowerCase() == widget.destinationStop.trim().toLowerCase(),
    );

    // 1. Bus reached Passenger's Source Stop
    if (pickupIdx != -1 &&
        !_hasShownSourceArrivalDialog &&
        (_currentBusIndex >= pickupIdx || _busProgress >= pickupIdx - 0.1)) {
      _hasShownSourceArrivalDialog = true;
      _boardedOrSourceArrivalTime ??= DateTime.now();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.directions_bus_filled_rounded, color: Color(0xFF2E7D32), size: 28),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Bus Has Arrived!",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF2E7D32)),
                ),
              ),
            ],
          ),
          content: Text(
            "${widget.callSign} has arrived at ${widget.pickupStop}. Please board safely and confirm 'Inside this bus? Yes' to track live destination ETA.",
            style: const TextStyle(fontSize: 14.5),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }

    // 2. Bus reached Passenger's Destination Stop
    if (destIdx != -1 &&
        !_hasShownDestinationDialog &&
        (_currentBusIndex >= destIdx || _busProgress >= destIdx - 0.1)) {
      _hasShownDestinationDialog = true;
      _stopCrowdsourcedGps();

      final startTime = _boardedOrSourceArrivalTime ?? DateTime.now().subtract(Duration(minutes: widget.initialEta));
      final elapsed = DateTime.now().difference(startTime);
      final journeyMinutes = elapsed.inMinutes < 1 ? 1 : elapsed.inMinutes;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.flag_circle_rounded, color: Color(0xFFC62828), size: 28),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Bus Reached Destination",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFFC62828)),
                ),
              ),
            ],
          ),
          content: Text(
            "You have arrived at ${widget.destinationStop}. Tap OK to view your journey summary.",
            style: const TextStyle(fontSize: 14.5),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              onPressed: () {
                Navigator.of(ctx).pop();
                _showJourneySummaryDialog(journeyMinutes);
              },
              child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  /// FSM Modal 3: Complete Passenger Journey Summary -> Returns to Fresh PassengerSearchScreen
  void _showJourneySummaryDialog(int journeyMinutes) {
    final double km = widget.journeyDistanceMeters / 1000.0;
    final String distanceFormatted = widget.journeyDistanceMeters >= 1000
        ? "${km.toStringAsFixed(2)} km"
        : "${widget.journeyDistanceMeters} m";
    final double avgSpeedKmh = journeyMinutes > 0 ? (km / (journeyMinutes / 60.0)) : 0.0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Column(
          children: [
            Text(
              "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFFC62828)),
            ),
            SizedBox(height: 4),
            Text(
              "Journey Summary",
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
            ),
          ],
        ),
        content: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFBFBFB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.black12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _summaryRow("Bus Service", widget.callSign),
              const Divider(height: 16),
              _summaryRow("Journey Route", "${widget.pickupStop} ➔ ${widget.destinationStop}"),
              const Divider(height: 16),
              _summaryRow("Journey Time", "$journeyMinutes min"),
              const Divider(height: 16),
              _summaryRow("Travel Distance", distanceFormatted),
              const Divider(height: 16),
              _summaryRow("Avg. Speed", "${avgSpeedKmh.clamp(5.0, 75.0).toStringAsFixed(1)} km/h"),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                // Pop back to root PassengerSearchScreen (which auto-resets dropdowns!)
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _issueDigitalTicket() async {
    setState(() => _isIssuingTicket = true);
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/tickets/issue'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'callSign': widget.callSign,
              'pickupStop': widget.pickupStop,
              'destinationStop': widget.destinationStop,
              'distanceMeters': widget.journeyDistanceMeters,
            }),
          )
          .timeout(const Duration(seconds: 6));

      final data = json.decode(resp.body);
      if (resp.statusCode == 200 && data['success'] == true && mounted) {
        setState(() {
          _activeDigitalTicket = Map<String, dynamic>.from(data['ticket']);
          _activeStudentPassId = null;
        });
        _showTicketPassModal();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not issue ticket. Check connection.")),
        );
      }
    } finally {
      if (mounted) setState(() => _isIssuingTicket = false);
    }
  }

  void _openStudentPassInput() {
    final ctrl = TextEditingController(text: _activeStudentPassId ?? 'STU-VJP-');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text("KKRTC Student Bus Pass", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: "Student Pass ID",
            hintText: "e.g., STU-VJP-4021",
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
            onPressed: () {
              final id = ctrl.text.trim().toUpperCase();
              if (id.length < 7) return;
              Navigator.of(ctx).pop();
              setState(() {
                _activeStudentPassId = id;
                _activeDigitalTicket = null;
              });
              _showTicketPassModal();
            },
            child: const Text("Activate Pass", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showTicketPassModal() {
    final bool isStudent = _activeStudentPassId != null;
    final String code = isStudent
        ? _activeStudentPassId!
        : (_activeDigitalTicket?['code']?.toString() ?? '------');
    final String sig = isStudent
        ? 'KKRTC-STUDENT-VERIFIED'
        : (_activeDigitalTicket?['signature']?.toString() ?? '');
    final String fare = isStudent
        ? 'FREE (Student Pass)'
        : '₹${_activeDigitalTicket?['fareInr'] ?? 10} PAID';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Column(
          children: [
            const Text(
              "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFC62828)),
            ),
            const SizedBox(height: 4),
            Text(
              isStudent ? "Digital Student Bus Pass" : "Verified Rush-Hour Ticket",
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F8E9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2E7D32), width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                  color: Color(0xFF1B5E20),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "SIG: $sig",
                style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: Colors.black54),
              ),
              const Divider(height: 18),
              _summaryRow("Bus ID", widget.callSign),
              const SizedBox(height: 6),
              _summaryRow("Route", "${widget.pickupStop} ➔ ${widget.destinationStop}"),
              const SizedBox(height: 6),
              _summaryRow("Status", fare),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Show to Conductor", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13.5, color: Color(0xFF212121), fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Starts crowdsourced passenger GPS contribution when "Inside this bus? Yes" is tapped
  Future<void> _startCrowdsourcedGps() async {
    await _crowdGpsStream?.cancel();

    try {
      bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;

      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
      );

      _crowdGpsStream = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
        if (!_isInsideBus || _socket == null) return;
        _socket!.emit('passenger:telemetry', {
          'callSign': widget.callSign,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'speed': (pos.speed * 3.6).clamp(0.0, 90.0),
        });
      });
    } catch (_) {}
  }

  Future<void> _stopCrowdsourcedGps() async {
    await _crowdGpsStream?.cancel();
    _crowdGpsStream = null;
  }

  @override
  void dispose() {
    _stopCrowdsourcedGps();
    _socket?.disconnect();
    _socket?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isReturn = widget.lockedDirection == 'RETURN';
    final pickupIdx = _displayedStops.indexWhere(
      (stop) => stop.trim().toLowerCase() == widget.pickupStop.trim().toLowerCase(),
    );
    final bool hasBusReachedSource = pickupIdx != -1 && (_currentBusIndex >= pickupIdx || _busProgress >= pickupIdx - 0.1);

    return Scaffold(
      backgroundColor: const Color(0xFFFBFBFB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          "${widget.callSign} • ${isReturn ? 'Return' : 'Outbound'}",
          style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            if (_isDetourActive)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 6.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE65100), width: 1.4),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.alt_route_rounded, color: Color(0xFFE65100), size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "DETOUR: Diverted via $_detourPathway. Will rejoin at $_rejoinStop.",
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFE65100),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_mlAnomalyType != 'NORMAL')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 6.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFC62828), width: 1.3),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.psychology_alt_rounded, color: Color(0xFFC62828), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _mlAnomalyType == 'ROUTE_DEVIATION'
                              ? "AI ALERT: Bus detected off standard corridor path."
                              : "AI TRAFFIC ALERT: Heavy congestion or unexpected delay ahead.",
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFB71C1C),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_stopSurgeMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 4.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1565C0), width: 1.2),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.groups_rounded, color: Color(0xFF1565C0), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _stopSurgeMessage!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0D47A1),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _stopSurgeMessage = null),
                        child: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF1565C0)),
                      ),
                    ],
                  ),
                ),
              ),

            // BUS STATUS CARD
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _isInsideBus
                                ? "You are ONBOARD this bus"
                                : (hasBusReachedSource
                                    ? "Bus Arrived at ${widget.pickupStop}"
                                    : "Bus is currently en route"),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: (_isInsideBus || hasBusReachedSource)
                                  ? const Color(0xFF2E7D32)
                                  : const Color(0xFFC62828),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            "Crowd: $_crowdLevel",
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isInsideBus
                          ? (_etaMinutes == 0
                              ? "Arrived at ${widget.destinationStop} (0 min)"
                              : "Arriving at ${widget.destinationStop} in $_etaMinutes min")
                          : (hasBusReachedSource
                              ? "Board now! Tap Yes below once seated"
                              : "ETA: $_etaMinutes min to ${widget.pickupStop}"),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: (_isInsideBus || hasBusReachedSource)
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFF00796B),
                      ),
                    ),
                    if (hasBusReachedSource || _showProximityOnboardPrompt || _isInsideBus) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1, color: Colors.black12),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text(
                            _showProximityOnboardPrompt && !_isInsideBus
                                ? "GPS detects you near bus. Inside?"
                                : "Inside this bus?",
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.black87),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _isInsideBus = true;
                                _showProximityOnboardPrompt = false;
                                _boardedOrSourceArrivalTime ??= DateTime.now();
                              });
                              _startCrowdsourcedGps();
                            },
                            child: Row(
                              children: [
                                Icon(
                                  _isInsideBus ? Icons.radio_button_checked : Icons.radio_button_off,
                                  size: 18,
                                  color: _isInsideBus ? const Color(0xFF2E7D32) : Colors.black54,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  "Yes",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: _isInsideBus ? FontWeight.bold : FontWeight.normal,
                                    color: _isInsideBus ? const Color(0xFF2E7D32) : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _isInsideBus = false;
                                _showProximityOnboardPrompt = false;
                              });
                            },
                            child: Row(
                              children: [
                                Icon(
                                  !_isInsideBus ? Icons.radio_button_checked : Icons.radio_button_off,
                                  size: 18,
                                  color: !_isInsideBus ? const Color(0xFFC62828) : Colors.black54,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  "No",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: !_isInsideBus ? FontWeight.bold : FontWeight.normal,
                                    color: !_isInsideBus ? const Color(0xFFC62828) : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_isInsideBus) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Text(
                              "Seat status:",
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black54),
                            ),
                            const SizedBox(width: 8),
                            for (final opt in [
                              {'key': 'SEATS', 'label': 'Seats'},
                              {'key': 'STANDING', 'label': 'Standing'},
                              {'key': 'FULL', 'label': 'Full'},
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(opt['label']!, style: const TextStyle(fontSize: 11)),
                                  selected: _crowdLevel == opt['key'],
                                  selectedColor: const Color(0xFF2E7D32).withValues(alpha: 0.2),
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (_) {
                                    setState(() => _crowdLevel = opt['key']!);
                                    _socket?.emit('passenger:crowd_vote', {
                                      'callSign': widget.callSign,
                                      'crowdLevel': opt['key'],
                                    });
                                  },
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFC62828),
                                  side: const BorderSide(color: Color(0xFFC62828)),
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                ),
                                onPressed: _isIssuingTicket
                                    ? null
                                    : (_activeDigitalTicket != null ? _showTicketPassModal : _issueDigitalTicket),
                                icon: const Icon(Icons.confirmation_number_outlined, size: 16),
                                label: Text(
                                  _activeDigitalTicket != null
                                      ? "Ticket: ${_activeDigitalTicket!['code']}"
                                      : "Get Digital Ticket",
                                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF2E7D32),
                                  side: const BorderSide(color: Color(0xFF2E7D32)),
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                ),
                                onPressed: _activeStudentPassId != null ? _showTicketPassModal : _openStudentPassInput,
                                icon: const Icon(Icons.badge_outlined, size: 16),
                                label: Text(
                                  _activeStudentPassId ?? "Student Pass",
                                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: _displayedStops.isEmpty
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                  : AsphaltRoadView(
                      stops: _displayedStops,
                      progress: _busProgress,
                      pickupStop: widget.pickupStop,
                      destinationStop: widget.destinationStop,
                      callSign: widget.callSign,
                      isReturnJourney: isReturn,
                      etaMinutes: _etaMinutes,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}