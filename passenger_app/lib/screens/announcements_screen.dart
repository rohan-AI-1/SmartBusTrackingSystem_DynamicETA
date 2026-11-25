// lib/screens/announcements_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';

class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<dynamic> _generalAnnouncements = [];
  bool _isLoadingGeneral = true;

  List<dynamic> _corridors = [];
  String? _selectedCorridorId;
  List<dynamic> _targetedAnnouncements = [];
  bool _isLoadingTargeted = false;

  Set<int> _hiddenAnnouncementIds = {};
  io.Socket? _socket;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadHiddenIds();
    _fetchGeneralAnnouncements();
    _fetchCorridors();
    _connectAnnouncementSocket();
  }

  void _connectAnnouncementSocket() {
    _socket = io.io(
      AppConfig.backendUrl,
      io.OptionBuilder().setTransports(['websocket', 'polling']).disableAutoConnect().build(),
    );

    _socket!.on('transit:announcement', (_) {
      if (!mounted) return;
      _fetchGeneralAnnouncements();
      if (_selectedCorridorId != null) {
        _fetchTargetedAnnouncements(_selectedCorridorId!);
      }
    });

    _socket!.on('transit:announcement_deleted', (data) {
      if (!mounted || data == null) return;
      final deletedId = data['id'] is int ? data['id'] : int.tryParse(data['id'].toString());
      if (deletedId != null) {
        setState(() {
          _generalAnnouncements.removeWhere((a) => a['id'] == deletedId);
          _targetedAnnouncements.removeWhere((a) => a['id'] == deletedId);
        });
      }
    });

    _socket!.connect();
  }

  @override
  void dispose() {
    _socket?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadHiddenIds() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('passenger_hidden_announcements') ?? [];
    if (mounted) {
      setState(() {
        _hiddenAnnouncementIds = saved
            .map((e) => int.tryParse(e) ?? -1)
            .where((id) => id != -1)
            .toSet();
      });
    }
  }

  Future<void> _deleteAnnouncementForPassenger(int id, {bool closeReader = false}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          "Delete Announcement?",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: const Text(
          "This announcement will be removed from your device.",
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel", style: TextStyle(color: Colors.black54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              "Delete",
              style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    _hiddenAnnouncementIds.add(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'passenger_hidden_announcements',
      _hiddenAnnouncementIds.map((e) => e.toString()).toList(),
    );

    if (mounted) {
      if (closeReader) Navigator.of(context).pop();
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Announcement deleted."),
          backgroundColor: Colors.black87,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _fetchGeneralAnnouncements() async {
    setState(() => _isLoadingGeneral = true);
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/announcements?scope=GENERAL'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (mounted) {
          setState(() {
            _generalAnnouncements = (decoded['announcements'] as List?) ?? [];
            _isLoadingGeneral = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingGeneral = false);
  }

  Future<void> _fetchCorridors() async {
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.backendUrl}/api/corridors'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (mounted) {
          setState(() {
            _corridors = (decoded['corridors'] as List?) ?? [];
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchTargetedAnnouncements(String corridorId) async {
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
            _targetedAnnouncements = (decoded['announcements'] as List?) ?? [];
            _isLoadingTargeted = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingTargeted = false);
  }

  String _formatRelativeTime(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${dt.day}/${dt.month}';
    } catch (_) {
      return '';
    }
  }

  void _openMessageReader(Map<String, dynamic> item) {
    final int id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
    final String title = item['title']?.toString() ?? 'Announcement';
    final String message = item['message']?.toString() ?? '';
    final String busId = item['conductor_call_sign']?.toString() ?? 'TRANSIT';
    final String priority = item['priority']?.toString() ?? 'ALERT';
    final String timeAgo = _formatRelativeTime(item['created_at']?.toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: priority == 'URGENT'
                      ? const Color(0xFFC62828)
                      : const Color(0xFF2E7D32),
                  child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "From: $busId",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Color(0xFF212121),
                        ),
                      ),
                      Text(
                        timeAgo,
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                if (priority == 'URGENT')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC62828),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      "URGENT",
                      style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF212121),
              ),
            ),
            const Divider(height: 24),
            Text(
              message,
              style: const TextStyle(
                fontSize: 15,
                height: 1.45,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                if (id != -1)
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFC62828),
                        side: const BorderSide(color: Color(0xFFC62828)),
                        minimumSize: const Size.fromHeight(44),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _deleteAnnouncementForPassenger(id, closeReader: true),
                      icon: const Icon(Icons.delete_outline_rounded, size: 19),
                      label: const Text("Delete", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                if (id != -1) const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC62828),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text("Close", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGmailStyleRow(dynamic rawItem, int serialNumber) {
    final item = Map<String, dynamic>.from(rawItem as Map);
    final int id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
    final String title = item['title']?.toString() ?? 'Announcement';
    final String preview = item['message']?.toString() ?? '';
    final String busId = item['conductor_call_sign']?.toString() ?? 'BUS';
    final String priority = item['priority']?.toString() ?? 'ALERT';
    final String timeAgo = _formatRelativeTime(item['created_at']?.toString());
    final bool isUrgent = priority == 'URGENT';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openMessageReader(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isUrgent ? const Color(0xFFC62828).withValues(alpha: 0.6) : Colors.black12,
              width: isUrgent ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: isUrgent
                    ? const Color(0xFFC62828).withValues(alpha: 0.12)
                    : const Color(0xFF2E7D32).withValues(alpha: 0.12),
                child: Text(
                  "$serialNumber",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isUrgent ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF212121),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeAgo,
                          style: const TextStyle(fontSize: 11.5, color: Colors.black45, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            busId,
                            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (id != -1)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFC62828), size: 20),
                  tooltip: "Delete announcement",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _deleteAnnouncementForPassenger(id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleGeneral = _generalAnnouncements.where((item) {
      final id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
      return !_hiddenAnnouncementIds.contains(id);
    }).toList();

    final visibleTargeted = _targetedAnnouncements.where((item) {
      final id = item['id'] is int ? item['id'] : int.tryParse(item['id'].toString()) ?? -1;
      return !_hiddenAnnouncementIds.contains(id);
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
            Tab(text: "General Announcements"),
            Tab(text: "Targeted Route"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: GENERAL ANNOUNCEMENTS
          RefreshIndicator(
            color: const Color(0xFFC62828),
            onRefresh: _fetchGeneralAnnouncements,
            child: _isLoadingGeneral
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                : visibleGeneral.isEmpty
                    ? ListView(
                        children: [
                          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
                          const Center(
                            child: Text(
                              "No general announcements right now.",
                              style: TextStyle(fontSize: 14, color: Colors.black54),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleGeneral.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (ctx, idx) =>
                            _buildGmailStyleRow(visibleGeneral[idx], idx + 1),
                      ),
          ),

          // TAB 2: TARGETED ROUTE ANNOUNCEMENTS
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
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
                      value: _selectedCorridorId,
                      hint: const Text(
                        "Choose Route to View Alerts",
                        style: TextStyle(fontSize: 14, color: Colors.black54),
                      ),
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
                          setState(() => _selectedCorridorId = val);
                          _fetchTargetedAnnouncements(val);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: _selectedCorridorId == null
                      ? const Center(
                          child: Text(
                            "Select a route above to check announcements.",
                            style: TextStyle(fontSize: 14, color: Colors.black54),
                          ),
                        )
                      : _isLoadingTargeted
                          ? const Center(child: CircularProgressIndicator(color: Color(0xFFC62828)))
                          : visibleTargeted.isEmpty
                              ? const Center(
                                  child: Text(
                                    "No announcements for this route.",
                                    style: TextStyle(fontSize: 14, color: Colors.black54),
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: visibleTargeted.length,
                                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                                  itemBuilder: (ctx, idx) =>
                                      _buildGmailStyleRow(visibleTargeted[idx], idx + 1),
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