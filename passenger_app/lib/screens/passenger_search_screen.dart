// lib/screens/passenger_search_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import 'announcements_screen.dart';
import 'bus_list_screen.dart';

class PassengerSearchScreen extends StatefulWidget {
  const PassengerSearchScreen({super.key});

  @override
  State<PassengerSearchScreen> createState() => _PassengerSearchScreenState();
}

class _PassengerSearchScreenState extends State<PassengerSearchScreen> {
  List<String> _stops = [];
  List<dynamic> _searchHistory = [];
  bool _isLoadingStops = true;

  String? _startStop;
  String? _endStop;

  @override
  void initState() {
    super.initState();
    _startStop = null;
    _endStop = null;
    _loadSearchHistory();
    _loadCachedAndLiveStops();
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('passenger_search_history');
    if (raw != null && mounted) {
      try {
        final decoded = json.decode(raw) as List;
        setState(() => _searchHistory = decoded);
      } catch (_) {}
    }
  }

  Future<void> _saveSearchToHistory(String start, String end) async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory.removeWhere(
      (item) =>
          item['start']?.toString().toLowerCase() == start.toLowerCase() &&
          item['end']?.toString().toLowerCase() == end.toLowerCase(),
    );
    _searchHistory.insert(0, {
      'start': start,
      'end': end,
      'timestamp': DateTime.now().toIso8601String(),
    });
    if (_searchHistory.length > 15) {
      _searchHistory = _searchHistory.sublist(0, 15);
    }
    await prefs.setString('passenger_search_history', json.encode(_searchHistory));
    if (mounted) setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('passenger_search_history');
    if (mounted) {
      setState(() => _searchHistory = []);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Search history cleared."),
          backgroundColor: Colors.black87,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openExternalForm(String urlString) async {
    final uri = Uri.parse(urlString);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        _showErrorDialog("Could Not Open Form", "Please ensure a browser is installed on your device.");
      }
    }
  }

  Future<void> _loadCachedAndLiveStops() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getStringList('cached_transit_stops');
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _stops = cached;
        _isLoadingStops = false;
      });
    }

    try {
      final response = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/stops'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final fetched = List<String>.from(data['stops'] ?? []);
        if (fetched.isNotEmpty) {
          await prefs.setStringList('cached_transit_stops', fetched);
          if (mounted) {
            setState(() {
              _stops = fetched;
              _isLoadingStops = false;
            });
          }
          return;
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoadingStops = false);
    }
  }

  Future<void> _executeSearch(String selectedStart, String selectedEnd) async {
    await _saveSearchToHistory(selectedStart, selectedEnd);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => BusListScreen(
          startStop: selectedStart,
          endStop: selectedEnd,
        ),
      ),
    );

    if (mounted) {
      setState(() {
        _startStop = null;
        _endStop = null;
      });
    }
  }

  Future<void> _handleFindMyBus() async {
    if (_startStop == null || _endStop == null) {
      _showErrorDialog("Incomplete Selection", "Please select both start and destination stops.");
      return;
    }

    if (_startStop!.trim().toLowerCase() == _endStop!.trim().toLowerCase()) {
      _showErrorDialog("Invalid Route", "Start stop and destination stop cannot be the same.");
      return;
    }

    await _executeSearch(_startStop!, _endStop!);
  }

  void _showErrorDialog(String title, String message) {
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
        iconTheme: const IconThemeData(color: Colors.black87, size: 28),
        title: const Text(
          "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ",
          style: TextStyle(
            color: Color(0xFF212121),
            fontWeight: FontWeight.bold,
            fontSize: 18,
            letterSpacing: 0.3,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFFC62828)),
            tooltip: "Refresh stops",
            onPressed: () {
              _loadCachedAndLiveStops();
            },
          ),
        ],
      ),
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(color: Color(0xFFC62828)),
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
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.campaign_rounded, color: Color(0xFFC62828)),
                title: const Text("Announcements", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("General & route-specific alerts", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AnnouncementsScreen()),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.rate_review_outlined, color: Color(0xFF2E7D32)),
                title: const Text("Feedback", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Rate app accuracy & report issues", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  _openExternalForm(AppConfig.feedbackFormUrl);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.lightbulb_outline_rounded, color: Color(0xFFE65100)),
                title: const Text("Suggestions", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Request new bus routes or services", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  _openExternalForm(AppConfig.suggestionFormUrl);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFC62828)),
                title: const Text("Clear Search History", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text("Remove saved recent routes", style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.of(context).pop();
                  _clearSearchHistory();
                },
              ),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 6),

         const SizedBox(height: 6),

              // TOP SEARCH BOX
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 20.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black26, width: 1.4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: _isLoadingStops
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24.0),
                        child: Center(
                          child: CircularProgressIndicator(color: Color(0xFFC62828)),
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildStopDropdown(
                            label: "Select Source Stop",
                            value: _startStop,
                            icon: Icons.trip_origin_rounded,
                            iconColor: const Color(0xFF2E7D32),
                            onChanged: (val) => setState(() => _startStop = val),
                          ),
                          const SizedBox(height: 14),
                          _buildStopDropdown(
                            label: "Select Destination Stop",
                            value: _endStop,
                            icon: Icons.location_on_rounded,
                            iconColor: const Color(0xFFC62828),
                            onChanged: (val) => setState(() => _endStop = val),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            height: 46,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFC62828),
                                foregroundColor: Colors.white,
                                elevation: 1,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _handleFindMyBus,
                              child: const Text(
                                "Find my bus",
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),

              const SizedBox(height: 20),

              // SEARCH HISTORY SECTION (Where Is My Train Style)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.history_rounded, size: 19, color: Colors.black54),
                      SizedBox(width: 6),
                      Text(
                        "Search History",
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF212121),
                        ),
                      ),
                    ],
                  ),
                  if (_searchHistory.isNotEmpty)
                    Text(
                      "${_searchHistory.length} recent",
                      style: const TextStyle(fontSize: 12, color: Colors.black45, fontWeight: FontWeight.w600),
                    ),
                ],
              ),

              const SizedBox(height: 10),

              Expanded(
                child: _searchHistory.isEmpty
                    ? Center(
                        child: Text(
                          "Your recent route searches will appear here.",
                          style: TextStyle(fontSize: 13.5, color: Colors.grey.shade500),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _searchHistory.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _searchHistory[index] as Map;
                          final start = entry['start']?.toString() ?? '';
                          final end = entry['end']?.toString() ?? '';

                          return Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _executeSearch(start, end),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.black12),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.directions_bus_outlined, color: Color(0xFFC62828), size: 20),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        "$start  ➔  $end",
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF212121),
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.black45),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStopDropdown({
    required String label,
    required String? value,
    required IconData icon,
    required Color iconColor,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black38, width: 1.2),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: Text(label, style: const TextStyle(fontSize: 14, color: Colors.black54)),
                value: (_stops.contains(value)) ? value : null,
                icon: const Icon(Icons.arrow_drop_down, color: Colors.black87, size: 26),
                items: _stops.map((stop) {
                  return DropdownMenuItem<String>(
                    value: stop,
                    child: Text(
                      stop,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF212121),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}