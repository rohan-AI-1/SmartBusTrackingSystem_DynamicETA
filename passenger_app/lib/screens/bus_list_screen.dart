// lib/screens/bus_list_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'live_road_tracking_screen.dart';

class BusListScreen extends StatefulWidget {
  final String startStop;
  final String endStop;

  const BusListScreen({
    super.key,
    required this.startStop,
    required this.endStop,
  });

  @override
  State<BusListScreen> createState() => _BusListScreenState();
}

class _BusListScreenState extends State<BusListScreen> {
  bool _isLoading = true;
  int _selectedCategory = 0; // 0: Incoming Direct, 1: Recently Passed (Catch), 2: Transfer Routes
  List<dynamic> _directBuses = [];
  List<dynamic> _recentlyPassedBuses = [];
  List<dynamic> _transferSuggestions = [];

  @override
  void initState() {
    super.initState();
    _fetchMatchingBuses();
  }

  Future<void> _fetchMatchingBuses() async {
    setState(() => _isLoading = true);

    try {
      final url = Uri.parse(
        '${AppConfig.backendUrl}/api/search?startStop=${Uri.encodeComponent(widget.startStop)}&endStop=${Uri.encodeComponent(widget.endStop)}',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _directBuses = data['buses'] as List? ?? [];
          _recentlyPassedBuses = data['recentlyPassedBuses'] as List? ?? [];
          _transferSuggestions = data['transferSuggestions'] as List? ?? [];
          _isLoading = false;
        });
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _directBuses = [];
        _recentlyPassedBuses = [];
        _transferSuggestions = [];
        _isLoading = false;
      });
    }
  }

  void _onBusCardTapped(dynamic rawBus) {
    final bus = Map<String, dynamic>.from(rawBus as Map);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => LiveRoadTrackingScreen(
          callSign: bus['callSign'] ?? "BUS100",
          corridorId: bus['corridorId'] ?? "CORRIDOR_1",
          corridorName: bus['corridorName'] ?? "${widget.startStop} ➔ ${widget.endStop}",
          pickupStop: bus['pickupStop'] ?? widget.startStop,
          destinationStop: bus['destinationStop'] ?? widget.endStop,
          initialEta: bus['etaMinutes'] ?? 1,
          lockedDirection: bus['direction'] ?? 'FORWARD',
          orderedStopNames: List<String>.from(bus['orderedStopNames'] ?? []),
          journeyDistanceMeters: (bus['passengerJourneyMeters'] as num?)?.toInt() ?? 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<dynamic> activeItems = _selectedCategory == 0
        ? _directBuses
        : (_selectedCategory == 1 ? _recentlyPassedBuses : _transferSuggestions);

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
          "Available Buses",
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFFC62828)),
            onPressed: _fetchMatchingBuses,
            tooltip: "Refresh available buses",
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.black12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.route_rounded, color: Color(0xFFC62828), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "${widget.startStop}  ➔  ${widget.endStop}",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF212121),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 3-OPTION CATEGORY SELECTOR
              Row(
                children: [
                  _buildCategoryTab(
                    index: 0,
                    title: "I. Incoming",
                    subtitle: "Direct (${_directBuses.length})",
                    activeColor: const Color(0xFF2E7D32),
                  ),
                  const SizedBox(width: 8),
                  _buildCategoryTab(
                    index: 1,
                    title: "II. Passed",
                    subtitle: "Catch (${_recentlyPassedBuses.length})",
                    activeColor: const Color(0xFFE65100),
                  ),
                  const SizedBox(width: 8),
                  _buildCategoryTab(
                    index: 2,
                    title: "III. Transfer",
                    subtitle: "Change (${_transferSuggestions.length})",
                    activeColor: const Color(0xFF1565C0),
                  ),
                ],
              ),

              const SizedBox(height: 14),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                    : RefreshIndicator(
                        color: const Color(0xFFC62828),
                        onRefresh: _fetchMatchingBuses,
                        child: activeItems.isEmpty
                            ? _buildCategoryEmptyState()
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: activeItems.length,
                                itemBuilder: (context, idx) {
                                  if (_selectedCategory == 0) {
                                    return _buildDirectBusCard(activeItems[idx]);
                                  } else if (_selectedCategory == 1) {
                                    return _buildRecentlyPassedCard(activeItems[idx]);
                                  } else {
                                    return _buildTransferCard(activeItems[idx]);
                                  }
                                },
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryTab({
    required int index,
    required String title,
    required String subtitle,
    required Color activeColor,
  }) {
    final bool selected = _selectedCategory == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedCategory = index),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? activeColor : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? activeColor : Colors.black26,
              width: 1.3,
            ),
          ),
          child: Column(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : Colors.black87,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white.withValues(alpha: 0.9) : activeColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryEmptyState() {
    final List<String> descriptions = [
      "No incoming buses heading directly from ${widget.startStop} to ${widget.endStop}.",
      "No buses have recently passed ${widget.startStop} within catchable distance.",
      "No 2-bus transfer connections needed or available for this route.",
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.14),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.directions_bus_outlined, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 14),
              const Text(
                "No buses of this type",
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28.0),
                child: Text(
                  descriptions[_selectedCategory],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: Colors.black54),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCrowdBadge(String crowdLevel) {
    Color color = const Color(0xFF2E7D32);
    String label = "Seats Free";
    if (crowdLevel == 'STANDING') {
      color = const Color(0xFFE65100);
      label = "Standing";
    } else if (crowdLevel == 'FULL') {
      color = const Color(0xFFC62828);
      label = "Full";
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _buildDirectBusCard(dynamic rawBus) {
    final bus = Map<String, dynamic>.from(rawBus as Map);
    final String callSign = bus['callSign'] ?? "BUS100";
    final String currentStop = bus['currentStop'] ?? "En route";
    final String nextStop = bus['nextStop'] ?? "Next Stop";
    final int eta = bus['etaMinutes'] ?? 1;
    final String crowdLevel = bus['crowdLevel'] ?? 'SEATS';

    return Padding(
      padding: const EdgeInsets.only(bottom: 14.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onBusCardTapped(bus),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.black12, width: 1.2),
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
                    Row(
                      children: [
                        const Icon(Icons.directions_bus_filled_rounded, color: Color(0xFFC62828), size: 24),
                        const SizedBox(width: 8),
                        Text(
                          callSign,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF212121),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildCrowdBadge(crowdLevel),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.sensors, size: 14, color: Color(0xFF2E7D32)),
                          SizedBox(width: 4),
                          Text(
                            "LIVE",
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  "Current Stop: $currentStop",
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.black87),
                ),
                const SizedBox(height: 4),
                Text(
                  "Next Stop: $nextStop",
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.black87),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "ETA: $eta min",
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFC62828),
                      ),
                    ),
                    const Row(
                      children: [
                        Text(
                          "Track live",
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black54),
                        ),
                        SizedBox(width: 4),
                        Icon(Icons.arrow_forward_ios_rounded, size: 13, color: Colors.black54),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentlyPassedCard(dynamic rawBus) {
    final bus = Map<String, dynamic>.from(rawBus as Map);
    final String callSign = bus['callSign'] ?? "BUS100";
    final String advice = bus['catchableAdvice'] ?? "Recently passed your stop.";
    final int passedMins = bus['passedMinutesAgo'] ?? 2;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onBusCardTapped(bus),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE65100), width: 1.2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.history_toggle_off_rounded, color: Color(0xFFE65100), size: 22),
                        const SizedBox(width: 8),
                        Text(
                          callSign,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE65100),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        "PASSED $passedMins MIN AGO",
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  advice,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    "View live position ➔",
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFFE65100)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransferCard(dynamic rawTransfer) {
    final transfer = Map<String, dynamic>.from(rawTransfer as Map);
    final String summary = transfer['summary'] ?? "";
    final firstLeg = Map<String, dynamic>.from(transfer['firstLeg'] as Map? ?? {});
    final secondLeg = Map<String, dynamic>.from(transfer['secondLeg'] as Map? ?? {});

    return Container(
      margin: const EdgeInsets.only(bottom: 14.0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1565C0), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.alt_route_rounded, color: Color(0xFF1565C0), size: 22),
              SizedBox(width: 8),
              Text(
                "2-Bus Interchange Route",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1565C0)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "1. Board ${firstLeg['corridorName']} (${firstLeg['fromStop']} ➔ ${firstLeg['alighAtStop']})",
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
          ),
          const SizedBox(height: 4),
          Text(
            "2. Transfer at ${firstLeg['alighAtStop']} to ${secondLeg['corridorName']} (➔ ${secondLeg['toStop']})",
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(summary, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ],
      ),
    );
  }

}