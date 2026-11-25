// lib/screens/conductor_announcements_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/trip_telemetry_service.dart';

class ConductorAnnouncementsScreen extends StatefulWidget {
  final String callSign;

  const ConductorAnnouncementsScreen({super.key, required this.callSign});

  @override
  State<ConductorAnnouncementsScreen> createState() =>
      _ConductorAnnouncementsScreenState();
}

class _ConductorAnnouncementsScreenState
    extends State<ConductorAnnouncementsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TripTelemetryService _telemetry = TripTelemetryService.instance;

  List<dynamic> _corridors = [];
  String? _selectedRouteId;

  List<dynamic> _targetedPublished = [];
  List<dynamic> _generalPublished = [];
  Set<int> _hiddenForMeIds = {};

  bool _isLoadingTargeted = false;
  bool _isLoadingGeneral = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initData() async {
    await _loadHiddenIds();
    await Future.wait([
      _fetchCorridors(),
      _fetchGeneralPublished(),
    ]);
  }

  Future<void> _loadHiddenIds() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('conductor_hidden_announcements_${widget.callSign}') ?? [];
    _hiddenForMeIds = saved.map((e) => int.tryParse(e) ?? -1).where((id) => id != -1).toSet();
  }

  Future<void> _hideForMeLocally(int announcementId) async {
    _hiddenForMeIds.add(announcementId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'conductor_hidden_announcements_${widget.callSign}',
      _hiddenForMeIds.map((e) => e.toString()).toList(),
    );
    if (mounted) setState(() {});
  }

  Future<void> _fetchCorridors() async {
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/corridors'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        final list = (decoded['corridors'] as List?) ?? [];
        if (mounted) {
          setState(() {
            _corridors = list;
            _selectedRouteId = _telemetry.corridorId ??
                (list.isNotEmpty ? list.first['corridorId']?.toString() : null);
          });
          if (_selectedRouteId != null) {
            _fetchTargetedPublished(_selectedRouteId!);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchTargetedPublished(String corridorId) async {
    setState(() => _isLoadingTargeted = true);
    try {
      final resp = await http
          .get(Uri.parse(
              '${AppConfig.backendUrl}/api/announcements?scope=TARGETED&corridorId=${Uri.encodeComponent(corridorId)}'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (mounted) {
          setState(() {
            _targetedPublished = (decoded['announcements'] as List?) ?? [];
            _isLoadingTargeted = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingTargeted = false);
  }

  Future<void> _fetchGeneralPublished() async {
    setState(() => _isLoadingGeneral = true);
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/announcements?scope=GENERAL'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (mounted) {
          setState(() {
            _generalPublished = (decoded['announcements'] as List?) ?? [];
            _isLoadingGeneral = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingGeneral = false);
  }

  /// Composer modal enforcing a meaningful Headline + Message
  void _openComposeDialog({required bool isTargeted}) {
    if (isTargeted && _selectedRouteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a target route first.")),
      );
      return;
    }

    final headlineController = TextEditingController();
    final messageController = TextEditingController();
    bool isUrgent = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            isTargeted ? "New Targeted Route Alert" : "New General Alert",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: headlineController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: "Headline (Required)",
                    hintText: "e.g., 10 min delay near Shivaji Circle",
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: messageController,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: "Full Message (Required)",
                    hintText: "Write clear details for passengers...",
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: const Color(0xFFC62828),
                  title: const Text(
                    "Mark as High Priority (URGENT)",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  value: isUrgent,
                  onChanged: (val) => setModalState(() => isUrgent = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Cancel", style: TextStyle(color: Colors.black54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              onPressed: () async {
                final headline = headlineController.text.trim();
                final body = messageController.text.trim();

                if (headline.length < 3 || body.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Please enter a clear Headline and Message."),
                      backgroundColor: Color(0xFFC62828),
                    ),
                  );
                  return;
                }

                Navigator.of(ctx).pop();

                try {
                  final token = await _telemetry.getAuthToken();
                  final resp = await http.post(
                    Uri.parse('${AppConfig.backendUrl}/api/announcements'),
                    headers: {
                      'Content-Type': 'application/json',
                      if (token != null) 'Authorization': 'Bearer $token',
                    },
                    body: json.encode({
                      'corridorId': isTargeted ? _selectedRouteId : 'ALL',
                      'callSign': widget.callSign,
                      'title': headline,
                      'message': body,
                      'priority': isUrgent ? 'URGENT' : 'ALERT',
                    }),
                  );

                  if (resp.statusCode == 200) {
                    if (isTargeted && _selectedRouteId != null) {
                      _fetchTargetedPublished(_selectedRouteId!);
                    } else {
                      _fetchGeneralPublished();
                    }
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Announcement published!"),
                          backgroundColor: Color(0xFF2E7D32),
                        ),
                      );
                    }
                  }
                } catch (_) {}
              },
              child: const Text("Publish", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// Fixed 3-Option Delete Dialog (WhatsApp-style) for conductors:
  /// 1) Delete for me and Passengers
  /// 2) Delete for me
  /// 3) Cancel
  void _confirmDeleteAnnouncement(Map<String, dynamic> item, {required bool isTargeted}) {
    final int id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
    final String owner = item['conductor_call_sign']?.toString() ?? '';
    final bool isMyOwn = owner == widget.callSign;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Delete Announcement?",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isMyOwn
                  ? "Remove \"${item['title']}\""
                  : "Published by $owner. Remove it from your list:",
              style: const TextStyle(fontSize: 13.5, color: Colors.black87),
            ),
            const SizedBox(height: 16),
            if (isMyOwn) ...[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC62828),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  try {
                    final token = await _telemetry.getAuthToken();
                    final resp = await http.delete(
                      Uri.parse('${AppConfig.backendUrl}/api/announcements/$id'),
                      headers: {
                        'Content-Type': 'application/json',
                        if (token != null) 'Authorization': 'Bearer $token',
                      },
                      body: json.encode({'callSign': widget.callSign}),
                    );
                    if (resp.statusCode == 200) {
                      if (isTargeted && _selectedRouteId != null) {
                        _fetchTargetedPublished(_selectedRouteId!);
                      } else {
                        _fetchGeneralPublished();
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Deleted for you and all passengers."),
                            backgroundColor: Colors.black87,
                          ),
                        );
                      }
                    }
                  } catch (_) {}
                },
                child: const Text(
                  "Delete for me and Passengers",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                ),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: const BorderSide(color: Colors.black38),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _hideForMeLocally(id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Deleted for you only."),
                      backgroundColor: Colors.black87,
                    ),
                  );
                }
              },
              child: const Text(
                "Delete for me",
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPublishedCard(dynamic rawItem, {required bool isTargeted}) {
    final item = Map<String, dynamic>.from(rawItem as Map);
    final String title = item['title']?.toString() ?? 'Announcement';
    final String message = item['message']?.toString() ?? '';
    final String owner = item['conductor_call_sign']?.toString() ?? 'BUS';
    final bool isUrgent = item['priority']?.toString() == 'URGENT';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isUrgent ? const Color(0xFFC62828).withValues(alpha: 0.6) : Colors.black12,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFC62828).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        owner,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC62828),
                        ),
                      ),
                    ),
                    if (isUrgent) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFC62828),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          "URGENT",
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF212121),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFC62828)),
            tooltip: "Delete announcement",
            onPressed: () => _confirmDeleteAnnouncement(item, isTargeted: isTargeted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleTargeted = _targetedPublished.where((item) {
      final id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
      return !_hiddenForMeIds.contains(id);
    }).toList();

    final visibleGeneral = _generalPublished.where((item) {
      final id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
      return !_hiddenForMeIds.contains(id);
    }).toList();

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
          "Announcements",
          style: TextStyle(color: Color(0xFF212121), fontWeight: FontWeight.bold, fontSize: 18),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: const Color(0xFFC62828),
          unselectedLabelColor: Colors.black54,
          indicatorColor: const Color(0xFFC62828),
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
          tabs: const [
            Tab(text: "Targeted Passengers"),
            Tab(text: "General Passengers"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: TARGETED PASSENGERS
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.black38, width: 1.2),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedRouteId,
                      hint: const Text("Select Target Route", style: TextStyle(fontSize: 14)),
                      items: _corridors.map((c) {
                        return DropdownMenuItem<String>(
                          value: c['corridorId']?.toString(),
                          child: Text(
                            c['corridorName']?.toString() ?? '',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedRouteId = val);
                          _fetchTargetedPublished(val);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFC62828),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _openComposeDialog(isTargeted: true),
                    icon: const Icon(Icons.add_alert_rounded, color: Colors.white, size: 20),
                    label: const Text(
                      "Announce to Selected Route",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  "Published Announcements (Targeted)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _isLoadingTargeted
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                      : visibleTargeted.isEmpty
                          ? const Center(
                              child: Text(
                                "No published route announcements.",
                                style: TextStyle(fontSize: 13.5, color: Colors.black54),
                              ),
                            )
                          : ListView.separated(
                              itemCount: visibleTargeted.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (ctx, idx) =>
                                  _buildPublishedCard(visibleTargeted[idx], isTargeted: true),
                            ),
                ),
              ],
            ),
          ),

          // TAB 2: GENERAL PASSENGERS
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _openComposeDialog(isTargeted: false),
                    icon: const Icon(Icons.campaign_rounded, color: Colors.white, size: 20),
                    label: const Text(
                      "Announce to All Passengers",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  "Published Announcements (General)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _isLoadingGeneral
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                      : visibleGeneral.isEmpty
                          ? const Center(
                              child: Text(
                                "No published general announcements.",
                                style: TextStyle(fontSize: 13.5, color: Colors.black54),
                              ),
                            )
                          : ListView.separated(
                              itemCount: visibleGeneral.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (ctx, idx) =>
                                  _buildPublishedCard(visibleGeneral[idx], isTargeted: false),
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}