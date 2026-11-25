// lib/widgets/asphalt_road_painter.dart
import 'package:flutter/material.dart';

class AsphaltRoadView extends StatefulWidget {
  final List<String> stops;
  final double progress;
  final String pickupStop;
  final String destinationStop;
  final String callSign;
  final bool isReturnJourney;
  final int? etaMinutes;

  const AsphaltRoadView({
    super.key,
    required this.stops,
    required this.progress,
    this.pickupStop = '',
    this.destinationStop = '',
    required this.callSign,
    this.isReturnJourney = false,
    this.etaMinutes,
  });

  @override
  State<AsphaltRoadView> createState() => _AsphaltRoadViewState();
}

class _AsphaltRoadViewState extends State<AsphaltRoadView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late AnimationController _pulseController;
  bool _userScrolledAway = false;

  static const double _stopSpacing = 175.0;
  static const double _topPadding = 78.0;

  int get _stopCount => widget.stops.length;

  int get currentStopIndex =>
      _stopCount == 0 ? 0 : widget.progress.floor().clamp(0, _stopCount - 1);

  int get _pickupIndex => widget.stops.indexWhere(
      (s) => s.trim().toLowerCase() == widget.pickupStop.trim().toLowerCase());

  int get _destIndex => widget.stops.indexWhere(
      (s) => s.trim().toLowerCase() == widget.destinationStop.trim().toLowerCase());

  /// Outbound (FORWARD): origin is at the bottom (index N-1), bus climbs UP (toward 0).
  /// Return (RETURN): origin is at the top (index 0), bus travels DOWN (toward N-1).
  double get _visualBusIndex {
    if (_stopCount <= 1) return 0.0;
    final clamped = widget.progress.clamp(0.0, (_stopCount - 1).toDouble());
    return widget.isReturnJourney ? clamped : ((_stopCount - 1) - clamped);
  }

  double _visualStopRow(int logicalIndex) {
    if (_stopCount <= 1) return 0.0;
    return widget.isReturnJourney
        ? logicalIndex.toDouble()
        : ((_stopCount - 1) - logicalIndex).toDouble();
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBus(animate: false));
  }

  @override
  void didUpdateWidget(covariant AsphaltRoadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_userScrolledAway &&
        ((oldWidget.progress - widget.progress).abs() > 0.015 ||
            oldWidget.isReturnJourney != widget.isReturnJourney)) {
      _scrollToBus(animate: true);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBus({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final double busY = (_visualBusIndex * _stopSpacing) + _topPadding;
    final double viewportHeight = _scrollController.position.viewportDimension;
    final double maxScroll = _scrollController.position.maxScrollExtent;
    final double target = (busY - (viewportHeight * 0.45)).clamp(0.0, maxScroll);

    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  String _buildPassengerBannerMessage() {
    if (_stopCount == 0) return "Loading route stops...";

    final int pIdx = _pickupIndex;
    final int dIdx = _destIndex;

    if (pIdx != -1) {
      final double stopsToPickup = pIdx - widget.progress;
      if (stopsToPickup > 0.25) {
        final int count = stopsToPickup.ceil();
        return "$count ${count == 1 ? 'stop' : 'stops'} away from ${widget.pickupStop}";
      } else if (stopsToPickup >= -0.25) {
        return "Bus arriving at ${widget.pickupStop} now!";
      }
    }

    if (dIdx != -1) {
      final double stopsToDest = dIdx - widget.progress;
      if (stopsToDest > 0.25) {
        final int count = stopsToDest.ceil();
        return "En route • $count ${count == 1 ? 'stop' : 'stops'} to ${widget.destinationStop}";
      } else if (stopsToDest >= -0.3) {
        return "Arriving at your destination: ${widget.destinationStop}";
      } else {
        return "Bus has passed ${widget.destinationStop}";
      }
    }

    return "Live on ${widget.isReturnJourney ? 'Rebound' : 'Outbound'} Pathway";
  }

  @override
  Widget build(BuildContext context) {
    final double totalHeight = (_stopCount * _stopSpacing) + 120;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double screenWidth = constraints.maxWidth;
        final double roadWidth = (screenWidth * 0.30).clamp(112.0, 148.0);

        // Road permanently anchored on the right side
        final double roadLeft = screenWidth - roadWidth - 16.0;
        final double roadCenter = roadLeft + (roadWidth / 2);

        // Clean stop cards occupy the left side
        const double cardLeft = 16.0;
        final double cardWidth = (roadLeft - cardLeft - 14.0).clamp(150.0, screenWidth);

        final double busTop = (_visualBusIndex * _stopSpacing) + _topPadding - 32;

        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null &&
                    !_userScrolledAway) {
                  setState(() => _userScrolledAway = true);
                }
                return false;
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Container(
                  height: totalHeight,
                  width: screenWidth,
                  color: const Color(0xFFF5F6F8), // Clean neutral slate surface
                  child: Stack(
                    children: [
                      // 1. Minimalist Right-Hand Asphalt Road
                      CustomPaint(
                        size: Size(screenWidth, totalHeight),
                        painter: _CleanPassengerRoadPainter(
                          roadLeft: roadLeft,
                          roadWidth: roadWidth,
                          roadCenter: roadCenter,
                          stopCount: _stopCount,
                          stopSpacing: _stopSpacing,
                          topPadding: _topPadding,
                          pickupVisualRow:
                              _pickupIndex != -1 ? _visualStopRow(_pickupIndex) : null,
                          destVisualRow:
                              _destIndex != -1 ? _visualStopRow(_destIndex) : null,
                        ),
                      ),

                      // 2. Clean Stop Cards along the left curb
                      for (int i = 0; i < _stopCount; i++)
                        Positioned(
                          top: (_visualStopRow(i) * _stopSpacing) + _topPadding - 22,
                          left: cardLeft,
                          width: cardWidth,
                          child: _buildCleanStopCard(
                            index: i,
                            stopName: widget.stops[i],
                            isPickup: i == _pickupIndex,
                            isDestination: i == _destIndex,
                            isInPassengerTrip: (_pickupIndex != -1 &&
                                _destIndex != -1 &&
                                i >= _pickupIndex &&
                                i <= _destIndex),
                            isPassed: i < currentStopIndex,
                            isCurrent: i == currentStopIndex,
                          ),
                        ),

                      // 3. Realistic Red City Bus Marker
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 1000),
                        curve: Curves.easeOutCubic,
                        top: busTop,
                        left: roadCenter - 23,
                        child: _buildRealisticBusMarker(),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Top Commuter Live Guidance Banner
            Positioned(
              top: 10,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1F24).withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: widget.isReturnJourney
                            ? const Color(0xFFE65100)
                            : const Color(0xFF2E7D32),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.isReturnJourney
                                ? Icons.south_rounded
                                : Icons.north_rounded,
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            widget.isReturnJourney ? "REBOUND" : "OUTBOUND",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        _buildPassengerBannerMessage(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.etaMinutes != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFC62828),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          "${widget.etaMinutes} min",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Floating Locate Bus button if user scrolls manually
            if (_userScrolledAway)
              Positioned(
                bottom: 16,
                left: 16,
                child: FloatingActionButton.small(
                  backgroundColor: const Color(0xFFC62828),
                  foregroundColor: Colors.white,
                  tooltip: "Locate Bus",
                  onPressed: () {
                    setState(() => _userScrolledAway = false);
                    _scrollToBus(animate: true);
                  },
                  child: const Icon(Icons.my_location_rounded, size: 20),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCleanStopCard({
    required int index,
    required String stopName,
    required bool isPickup,
    required bool isDestination,
    required bool isInPassengerTrip,
    required bool isPassed,
    required bool isCurrent,
  }) {
    final Color borderColor = isPickup
        ? const Color(0xFF2E7D32)
        : (isDestination
            ? const Color(0xFFC62828)
            : (isCurrent ? const Color(0xFF263238) : const Color(0xFFE0E4EA)));

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: isPickup
                  ? const Color(0xFFF1F8E9)
                  : (isDestination
                      ? const Color(0xFFFFF8F6)
                      : (isInPassengerTrip
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.72))),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: borderColor,
                width: (isPickup || isDestination || isCurrent) ? 1.8 : 1.1,
              ),
              boxShadow: [
                if (!isPassed || isPickup || isDestination)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: isPickup
                        ? const Color(0xFF2E7D32)
                        : (isDestination
                            ? const Color(0xFFC62828)
                            : (isPassed
                                ? const Color(0xFF2E7D32).withValues(alpha: 0.14)
                                : const Color(0xFFF0F2F5))),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: isPickup
                        ? const Icon(Icons.hail_rounded, size: 13, color: Colors.white)
                        : (isDestination
                            ? const Icon(Icons.flag_rounded,
                                size: 13, color: Colors.white)
                            : (isPassed
                                ? const Icon(Icons.check_rounded,
                                    size: 14, color: Color(0xFF2E7D32))
                                : Text(
                                    "${index + 1}",
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF455A64),
                                    ),
                                  ))),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stopName,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: (isPickup || isDestination || isCurrent)
                          ? FontWeight.bold
                          : FontWeight.w600,
                      color: isPassed && !isPickup && !isDestination
                          ? Colors.black38
                          : (isPickup
                              ? const Color(0xFF1B5E20)
                              : (isDestination
                                  ? const Color(0xFFC62828)
                                  : const Color(0xFF1E242B))),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isPickup) _buildTag("BOARD", const Color(0xFF2E7D32)),
                if (isDestination) _buildTag("GET OFF", const Color(0xFFC62828)),
              ],
            ),
          ),
        ),
        // Subtle horizontal connector tick toward the road curb
        Container(
          width: 12,
          height: 2,
          color: isPickup
              ? const Color(0xFF2E7D32)
              : (isDestination
                  ? const Color(0xFFC62828)
                  : (isInPassengerTrip
                      ? const Color(0xFF66BB6A)
                      : const Color(0xFFCFD8DC))),
        ),
      ],
    );
  }

  Widget _buildTag(String text, Color bg) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildRealisticBusMarker() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final double glow = 3.0 + (_pulseController.value * 6.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 68,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFC62828).withValues(alpha: 0.38),
                    blurRadius: 10 + glow,
                    spreadRadius: glow * 0.35,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: CustomPaint(
                painter: _RealCityBusPainter(
                  isHeadingDown: widget.isReturnJourney,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1F24),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white70, width: 0.8),
              ),
              child: Text(
                widget.callSign,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Custom vector painter modeled after the red Tata / JnNURM city bus livery
class _RealCityBusPainter extends CustomPainter {
  final bool isHeadingDown;

  _RealCityBusPainter({required this.isHeadingDown});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (isHeadingDown) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate(3.14159265);
      canvas.translate(-size.width / 2, -size.height / 2);
    }

    final double w = size.width;
    final double h = size.height;
    const double bodyLeft = 5.0;
    final double bodyRight = w - 5.0;
    final double bodyW = bodyRight - bodyLeft;

    // 1. Side Rear-View Mirrors
    final Paint mirrorPaint = Paint()
      ..color = const Color(0xFF212121)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(bodyLeft, 13)
        ..lineTo(1.5, 10)
        ..lineTo(1.5, 15),
      mirrorPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(bodyRight, 13)
        ..lineTo(w - 1.5, 10)
        ..lineTo(w - 1.5, 15),
      mirrorPaint,
    );

    // 2. Main Crimson Red Coach Body
    final RRect bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(bodyLeft, 2, bodyW, h - 4),
      const Radius.circular(8),
    );
    final Paint bodyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0xFF9E1B1B),
          Color(0xFFD32F2F),
          Color(0xFFB71C1C),
        ],
      ).createShader(bodyRect.outerRect);
    canvas.drawRRect(bodyRect, bodyPaint);

    // 3. Gold/Yellow JnNURM Side Accent Stripes & Emblem Dot
    final Paint goldStripe = Paint()
      ..color = const Color(0xFFFFC107)
      ..strokeWidth = 1.6;
    canvas.drawLine(Offset(bodyLeft + 1.5, 22), Offset(bodyLeft + 1.5, h - 10), goldStripe);
    canvas.drawLine(Offset(bodyRight - 1.5, 22), Offset(bodyRight - 1.5, h - 10), goldStripe);
    canvas.drawCircle(
      Offset(bodyLeft + 3.2, h * 0.56),
      2.4,
      Paint()..color = const Color(0xFFFFCA28),
    );

    // 4. Panoramic Tinted Front Windshield
    final RRect windshield = RRect.fromRectAndRadius(
      Rect.fromLTWH(bodyLeft + 3.5, 6, bodyW - 7.0, 12),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      windshield,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF102027), Color(0xFF37474F)],
        ).createShader(windshield.outerRect),
    );
    canvas.drawLine(
      Offset(bodyLeft + 6, 8.5),
      Offset(bodyLeft + 14, 15),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..strokeWidth = 1.5,
    );

    // 5. Roof Ventilation Hatches
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyLeft + 6, 23, bodyW - 12, 14),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF8E1616),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyLeft + 7, 42, bodyW - 14, 12),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF8E1616),
    );

    // 6. Rear Window Glass
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyLeft + 5, h - 8.5, bodyW - 10, 4.5),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF1C262B),
    );

    // 7. Twin Front Headlights
    final Paint headlightPaint = Paint()..color = const Color(0xFFFFF59D);
    canvas.drawCircle(Offset(bodyLeft + 5.5, 4.0), 1.8, headlightPaint);
    canvas.drawCircle(Offset(bodyRight - 5.5, 4.0), 1.8, headlightPaint);

    // 8. Crisp White Coach Outline
    canvas.drawRRect(
      bodyRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RealCityBusPainter oldDelegate) =>
      oldDelegate.isHeadingDown != isHeadingDown;
}

class _CleanPassengerRoadPainter extends CustomPainter {
  final double roadLeft;
  final double roadWidth;
  final double roadCenter;
  final int stopCount;
  final double stopSpacing;
  final double topPadding;
  final double? pickupVisualRow;
  final double? destVisualRow;

  _CleanPassengerRoadPainter({
    required this.roadLeft,
    required this.roadWidth,
    required this.roadCenter,
    required this.stopCount,
    required this.stopSpacing,
    required this.topPadding,
    required this.pickupVisualRow,
    required this.destVisualRow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Dark Charcoal Asphalt Surface
    canvas.drawRect(
      Rect.fromLTWH(roadLeft, 0, roadWidth, size.height),
      Paint()..color = const Color(0xFF1E2126),
    );

    // 2. Solid White Boundary Lines
    final Paint edgeLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 2.6;
    canvas.drawLine(Offset(roadLeft + 3, 0), Offset(roadLeft + 3, size.height), edgeLine);
    canvas.drawLine(
        Offset(roadLeft + roadWidth - 3, 0), Offset(roadLeft + roadWidth - 3, size.height), edgeLine);

    // 3. Highlight Passenger's Selected Segment (Boarding -> Destination) along Left Curb
    if (pickupVisualRow != null && destVisualRow != null) {
      final double y1 = (pickupVisualRow! * stopSpacing) + topPadding;
      final double y2 = (destVisualRow! * stopSpacing) + topPadding;
      canvas.drawLine(
        Offset(roadLeft + 2.5, y1),
        Offset(roadLeft + 2.5, y2),
        Paint()
          ..color = const Color(0xFF43A047)
          ..strokeWidth = 5.0
          ..style = PaintingStyle.stroke,
      );
    }

    // 4. Clean Dashed Center Line
    final Paint centerDash = Paint()
      ..color = Colors.white.withValues(alpha: 0.65)
      ..strokeWidth = 2.0;
    double y = 14.0;
    while (y < size.height) {
      canvas.drawLine(Offset(roadCenter, y), Offset(roadCenter, y + 20.0), centerDash);
      y += 36.0;
    }

    // 5. Minimal White Curbside Stop Markers (no chevrons)
    final Paint stopTick = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 2.4;

    for (int i = 0; i < stopCount; i++) {
      final double stopY = (i * stopSpacing) + topPadding;
      canvas.drawLine(
        Offset(roadLeft + 6, stopY),
        Offset(roadLeft + 24, stopY),
        stopTick,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CleanPassengerRoadPainter oldDelegate) =>
      oldDelegate.roadLeft != roadLeft ||
      oldDelegate.roadWidth != roadWidth ||
      oldDelegate.pickupVisualRow != pickupVisualRow ||
      oldDelegate.destVisualRow != destVisualRow;
}