// lib/screens/live_trip_screen.dart
import 'package:flutter/material.dart';
import '../services/trip_telemetry_service.dart';
import '../widgets/asphalt_road_painter.dart';

class LiveTripScreen extends StatefulWidget {
  const LiveTripScreen({super.key});

  @override
  State<LiveTripScreen> createState() => _LiveTripScreenState();
}

class _LiveTripScreenState extends State<LiveTripScreen> {
  final TripTelemetryService _telemetry = TripTelemetryService.instance;

  @override
  void initState() {
    super.initState();
    _telemetry.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _telemetry.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
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
        title: Text(
          "Live Tracking (${_telemetry.activeDirection})",
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _telemetry.isSocketConnected
                      ? const Color(0xFFE8F5E9)
                      : const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _telemetry.isSocketConnected
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFEF6C00),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _telemetry.isSocketConnected ? Icons.wifi_tethering_rounded : Icons.cloud_off_rounded,
                      size: 14,
                      color: _telemetry.isSocketConnected
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFEF6C00),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _telemetry.isSocketConnected
                          ? "WS • ${_telemetry.lastRttMs ?? '--'}ms • #${_telemetry.lastPacketSeq}"
                          : "BUFFERED (${_telemetry.bufferedPacketCount})",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _telemetry.isSocketConnected
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFEF6C00),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.black12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.speed_rounded, color: Color(0xFFC62828), size: 24),
                        const SizedBox(width: 8),
                        Text(
                          "Speed: ${_telemetry.currentSpeed.toStringAsFixed(0)} km/h",
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF212121),
                          ),
                        ),
                      ],
                    ),
                    Container(width: 1, height: 24, color: Colors.black12),
                    Row(
                      children: [
                        const Icon(Icons.timer_outlined, color: Color(0xFF00796B), size: 22),
                        const SizedBox(width: 8),
                        Text(
                          "ETA: ${_telemetry.terminalEtaMinutes} min",
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00796B),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_telemetry.headwayAdvice != null && _telemetry.headwayAdvice!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20.0, right: 20.0, top: 10.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE65100), width: 1.4),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.timelapse_rounded, color: Color(0xFFE65100), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _telemetry.headwayAdvice!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFE65100),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_telemetry.transferHoldMessage != null && _telemetry.transferHoldMessage!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20.0, right: 20.0, top: 8.0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF1565C0), width: 1.4),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.transfer_within_a_station_rounded, color: Color(0xFF1565C0), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _telemetry.transferHoldMessage!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0D47A1),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Quick Diversion Switcher (Normal / Siddheshwar Festival / Roadwork / Strike)
            Padding(
              padding: const EdgeInsets.only(left: 20.0, right: 20.0, top: 10.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final item in [
                      {'code': 'NONE', 'label': 'Normal Route'},
                      {'code': 'SIDDESHWAR_FESTIVAL', 'label': 'Siddheshwar Festival'},
                      {'code': 'GOVT_ROADWORK', 'label': 'Roadwork Bypass'},
                      {'code': 'STRIKE_BYPASS', 'label': 'Strike Bypass'},
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6.0),
                        child: ChoiceChip(
                          label: Text(item['label']!, style: const TextStyle(fontSize: 11)),
                          selected: _telemetry.activeDiversionCode == item['code'],
                          selectedColor: item['code'] == 'NONE'
                              ? const Color(0xFF2E7D32).withValues(alpha: 0.2)
                              : const Color(0xFFE65100).withValues(alpha: 0.2),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => _telemetry.setDiversionProfile(item['code']!),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),
            Expanded(
              child: _telemetry.displayedStops.isEmpty
                  ? const Center(child: Text("Waiting for route stops..."))
                  : AsphaltRoadView(
                      stops: _telemetry.displayedStops,
                      progress: _telemetry.busProgress,
                      callSign: _telemetry.callSign ?? "BUS",
                      isReturnJourney: _telemetry.activeDirection == 'RETURN',
                      speedKmh: _telemetry.currentSpeed,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}