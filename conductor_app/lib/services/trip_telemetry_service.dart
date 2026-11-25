// lib/services/trip_telemetry_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../config/app_config.dart';

class TripTelemetryService extends ChangeNotifier {
  static final TripTelemetryService instance = TripTelemetryService._internal();
  TripTelemetryService._internal();

  io.Socket? _socket;
  StreamSubscription<Position>? _gpsStream;

  String? _callSign;
  String? _corridorId;
  String? _corridorName;
  String? _authToken;

  bool _isTripActive = false;
  String _activeDirection = 'FORWARD';
  List<String> _displayedStops = [];
  double _busProgress = 0.0;
  double _currentSpeed = 0.0;
  int _terminalEtaMinutes = 0;
  bool _hasReachedOrigin = false;
  String _crowdLevel = 'SEATS'; // 'SEATS' | 'STANDING' | 'FULL'
  bool _isSocketConnected = false;
  String? _headwayAdvice;
  int _headwayHoldSeconds = 0;
  String? _transferHoldMessage;
  String _activeDiversionCode = 'NONE';

  // Offline buffer & Computer Networks telemetry instrumentation
  final List<dynamic> _offlineTelemetryQueue = [];
  DateTime? _lastSentTimestamp;
  int _packetSeq = 0;
  int? _lastRttMs;
  Timer? _rttTimer;

  // Getters for UI screens
  bool get isTripActive => _isTripActive;
  String? get callSign => _callSign;
  String? get corridorId => _corridorId;
  String? get corridorName => _corridorName;
  String get activeDirection => _activeDirection;
  List<String> get displayedStops => _displayedStops;
  double get busProgress => _busProgress;
  double get currentSpeed => _currentSpeed;
  int get terminalEtaMinutes => _terminalEtaMinutes;
  bool get hasReachedOrigin => _hasReachedOrigin;
  String get crowdLevel => _crowdLevel;
  bool get isSocketConnected => _isSocketConnected;
  int get bufferedPacketCount => _offlineTelemetryQueue.length;
  int? get lastRttMs => _lastRttMs;
  int get lastPacketSeq => _packetSeq;
  String? get headwayAdvice => _headwayAdvice;
  int get headwayHoldSeconds => _headwayHoldSeconds;
  String? get transferHoldMessage => _transferHoldMessage;
  String get activeDiversionCode => _activeDiversionCode;

  Future<void> setAuthToken(String token) async {
    _authToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('conductor_auth_token', token);
  }

  Future<String?> getAuthToken() async {
    if (_authToken != null && _authToken!.isNotEmpty) return _authToken;
    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString('conductor_auth_token');
    return _authToken;
  }

  /// Starts a trip immediately (called when StartTripScreen or ChangeTripScreen confirms)
  Future<void> startTrip({
    required String callSign,
    required String corridorId,
    required String corridorName,
    required List<String> initialStops,
  }) async {
    _callSign = callSign;
    _corridorId = corridorId;
    _corridorName = corridorName;
    _activeDirection = 'FORWARD';
    _displayedStops = List<String>.from(initialStops);
    _busProgress = 0.0;
    _currentSpeed = 0.0;
    _hasReachedOrigin = false;
    _crowdLevel = 'SEATS';
    _packetSeq = 0;
    _lastRttMs = null;
    _terminalEtaMinutes = _displayedStops.length > 1 ? (_displayedStops.length - 1) * 3 : 0;
    _isTripActive = true;

    notifyListeners();

    await getAuthToken();
    await _restoreOfflineQueue();
    _initSocketAndStartTrip();
    await _startAdaptiveGpsStream();
  }

  /// Switches route mid-duty cleanly
  Future<void> changeRoute({
    required String newCorridorId,
    required String newCorridorName,
    required List<String> newStops,
  }) async {
    if (_callSign == null) return;

    final token = await getAuthToken();

    try {
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/trips/stop'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({'callSign': _callSign}),
      );
    } catch (_) {}

    _corridorId = newCorridorId;
    _corridorName = newCorridorName;
    _activeDirection = 'FORWARD';
    _displayedStops = List<String>.from(newStops);
    _busProgress = 0.0;
    _hasReachedOrigin = false;
    _terminalEtaMinutes = _displayedStops.length > 1 ? (_displayedStops.length - 1) * 3 : 0;

    _socket?.emit('conductor:start_trip', {
      'callSign': _callSign,
      'corridorId': _corridorId,
      'token': token,
    });

    notifyListeners();
  }

  /// Stops the active trip cleanly and shuts down GPS + Socket
  Future<void> stopTrip() async {
    final activeId = _callSign;

    _isTripActive = false;
    _corridorId = null;
    _corridorName = null;
    _displayedStops = [];
    _busProgress = 0.0;
    _currentSpeed = 0.0;
    _terminalEtaMinutes = 0;

    _rttTimer?.cancel();
    _rttTimer = null;

    await _gpsStream?.cancel();
    _gpsStream = null;

    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isSocketConnected = false;

    notifyListeners();

    if (activeId != null) {
      final token = await getAuthToken();
      try {
        await http.post(
          Uri.parse('${AppConfig.backendUrl}/api/trips/stop'),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: json.encode({'callSign': activeId}),
        );
      } catch (_) {}
    }
  }

  /// Zero-GPS fallback: Conductor manually confirms arrival at a stop index
  void manualStopCheckIn(int stopIndex) {
    if (!_isTripActive || _callSign == null) return;
    _socket?.emit('conductor:manual_stop_checkin', {
      'callSign': _callSign,
      'stopIndex': stopIndex,
      'token': _authToken,
    });
  }

  /// Updates seat/crowd occupancy ('SEATS' | 'STANDING' | 'FULL')
  void updateCrowdLevel(String level) {
    if (!_isTripActive || _callSign == null) return;
    _crowdLevel = level;
    notifyListeners();

    _socket?.emit('conductor:crowd_status', {
      'callSign': _callSign,
      'crowdLevel': level,
      'token': _authToken,
    });
  }

  /// Activates or clears a known festival/roadwork/strike diversion profile
  void setDiversionProfile(String profileCode) {
    if (!_isTripActive || _callSign == null) return;
    _activeDiversionCode = profileCode;
    notifyListeners();

    _socket?.emit('conductor:set_diversion', {
      'callSign': _callSign,
      'profileCode': profileCode,
      'token': _authToken,
    });
  }

  /// Broadcasts a real-time announcement to this route or all city passengers
  Future<bool> sendAnnouncement({
    required String title,
    required String message,
    required String targetCorridorId, // 'ALL' or specific corridorId
  }) async {
    final token = await getAuthToken();
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/announcements'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'corridorId': targetCorridorId,
          'callSign': _callSign ?? 'CONDUCTOR',
          'title': title,
          'message': message,
          'priority': 'ALERT',
        }),
      ).timeout(const Duration(seconds: 8));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _initSocketAndStartTrip() {
    _socket?.disconnect();
    _socket?.dispose();

    _socket = io.io(
      AppConfig.backendUrl,
      <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionAttempts': 99999,
        'reconnectionDelay': 1500,
      },
    );

    _socket?.onConnect((_) {
      _isSocketConnected = true;
      notifyListeners();

      _socket?.emit('conductor:start_trip', {
        'callSign': _callSign,
        'corridorId': _corridorId,
        'token': _authToken,
      });

      _startRttProbe();
      _flushOfflineQueue();
    });

    _socket?.onDisconnect((_) {
      _isSocketConnected = false;
      _rttTimer?.cancel();
      notifyListeners();
    });

    _socket?.on('bus:telemetry_stream', (data) {
      if (data == null || data['callSign'] != _callSign || !_isTripActive) return;

      if (data['orderedStops'] is List) {
        final serverStops = (data['orderedStops'] as List)
            .map((s) => s['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
        if (serverStops.isNotEmpty) {
          _displayedStops = serverStops;
        }
      }

      final String? newDirection = data['direction']?.toString().toUpperCase();
      if (newDirection == 'FORWARD' || newDirection == 'RETURN') {
        _activeDirection = newDirection!;
      }

      if (data['progress'] is num) {
        _busProgress = (data['progress'] as num).toDouble();
      }

      if (data['hasReachedOrigin'] is bool) {
        _hasReachedOrigin = data['hasReachedOrigin'];
      }

      if (!_hasReachedOrigin) {
        _terminalEtaMinutes = 0;
      } else if (_displayedStops.isNotEmpty) {
        final remainingStops = (_displayedStops.length - 1) - _busProgress;
        _terminalEtaMinutes = remainingStops <= 0.15
            ? 0
            : (remainingStops * 3).ceil().clamp(0, 180);
      }

      notifyListeners();
    });

    _socket?.on('conductor:headway_advice', (data) {
      if (data is! Map || data['callSign'] != _callSign || !_isTripActive) return;
      final bool bunching = data['isBunching'] == true;
      _headwayAdvice = bunching ? (data['advice']?.toString() ?? '') : null;
      _headwayHoldSeconds = bunching ? ((data['holdSeconds'] as num?)?.toInt() ?? 0) : 0;
      notifyListeners();
    });

    _socket?.on('conductor:transfer_hold', (data) {
      if (data is! Map || data['callSign'] != _callSign || !_isTripActive) return;
      _transferHoldMessage = data['message']?.toString();
      notifyListeners();
      Future.delayed(const Duration(seconds: 45), () {
        if (_transferHoldMessage == data['message']?.toString()) {
          _transferHoldMessage = null;
          notifyListeners();
        }
      });
    });
  }

  Future<void> _startAdaptiveGpsStream() async {
    await _gpsStream?.cancel();

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final AndroidSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 4,
      intervalDuration: const Duration(seconds: 3),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: "ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ — Live Duty",
        notificationText: "Broadcasting real-time bus location for passengers...",
        enableWakeLock: true,
      ),
    );

    _gpsStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        if (!_isTripActive || _callSign == null) return;

        double filteredSpeed = position.speed * 3.6;
        if (position.speed < 0.7 || position.accuracy > 25.0) {
          filteredSpeed = 0.0;
        }
        _currentSpeed = filteredSpeed.clamp(0.0, 90.0);

        final now = DateTime.now();
        if (_currentSpeed == 0.0 &&
            _lastSentTimestamp != null &&
            now.difference(_lastSentTimestamp!).inSeconds < 12) {
          notifyListeners();
          return;
        }
        _lastSentTimestamp = now;

        _packetSeq++;
        final payload = {
          'callSign': _callSign,
          'seq': _packetSeq,
          'token': _authToken,
          'lat': position.latitude,
          'lng': position.longitude,
          'speed': _currentSpeed,
          'heading': position.heading,
          'timestamp': now.toIso8601String(),
        };

        if (_isSocketConnected && _socket != null) {
          _socket!.emit('conductor:telemetry', payload);
        } else {
          _enqueueOfflineTelemetry(payload);
        }

        notifyListeners();
      },
      onError: (err) => debugPrint("GPS Stream Error: $err"),
    );
  }

  Future<void> _enqueueOfflineTelemetry(Map<String, dynamic> packet) async {
    if (_offlineTelemetryQueue.length >= 25) {
      _offlineTelemetryQueue.removeAt(0);
    }
    _offlineTelemetryQueue.add(packet);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('offline_telemetry_queue', json.encode(_offlineTelemetryQueue));
  }

  Future<void> _restoreOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('offline_telemetry_queue');
    if (raw != null) {
      try {
        final list = json.decode(raw) as List;
        _offlineTelemetryQueue
          ..clear()
          ..addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
      } catch (_) {}
    }
  }

  void _startRttProbe() {
    _rttTimer?.cancel();
    _measureRttOnce();
    _rttTimer = Timer.periodic(const Duration(seconds: 10), (_) => _measureRttOnce());
  }

  void _measureRttOnce() {
    if (!_isSocketConnected || _socket == null) return;
    final sentAt = DateTime.now().millisecondsSinceEpoch;
    _socket!.emitWithAck(
      'network:ping',
      {'clientSentAt': sentAt},
      ack: (dynamic response) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _lastRttMs = (now - sentAt).clamp(1, 9999);
        notifyListeners();
      },
    );
  }

  Future<void> _flushOfflineQueue() async {
    if (_offlineTelemetryQueue.isEmpty || !_isSocketConnected) return;

    final pending = List<dynamic>.from(_offlineTelemetryQueue);
    _offlineTelemetryQueue.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('offline_telemetry_queue');
    notifyListeners();

    // Paced FIFO replay (350ms spacing) to respect server Token-Bucket traffic policing
    for (final packet in pending) {
      if (!_isSocketConnected || _socket == null) {
        await _enqueueOfflineTelemetry(Map<String, dynamic>.from(packet as Map));
        break;
      }
      _socket!.emit('conductor:telemetry', packet);
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }
}