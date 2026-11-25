// src/services/etaService.js

const EARTH_RADIUS_METERS = 6371000;

/**
 * Exact Haversine distance in meters between two WGS84 coordinates.
 */
export function calculateHaversineDistance(lat1, lon1, lat2, lon2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) *
      Math.cos(toRad(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_METERS * c;
}

/**
 * Projects a raw GPS point (P) onto a road segment (A -> B) using local equirectangular
 * planar projection (accurate to <0.1m at city/district scale).
 * Returns snapped coordinates, perpendicular off-route distance (meters), and segment fraction [0..1].
 */
export function projectPointOntoSegment(pLat, pLng, aLat, aLng, bLat, bLng) {
  const cosLat = Math.cos(((aLat + bLat) / 2) * (Math.PI / 180));
  const metersPerDegLat = 111132.92;
  const metersPerDegLng = 111412.84 * cosLat;

  // Convert A, B, P into local planar meters relative to A
  const bx = (bLng - aLng) * metersPerDegLng;
  const by = (bLat - aLat) * metersPerDegLat;
  const px = (pLng - aLng) * metersPerDegLng;
  const py = (pLat - aLat) * metersPerDegLat;

  const segLenSq = bx * bx + by * by;
  let t = 0;
  if (segLenSq > 0) {
    t = (px * bx + py * by) / segLenSq;
    t = Math.max(0, Math.min(1, t));
  }

  const projX = t * bx;
  const projY = t * by;

  const dx = px - projX;
  const dy = py - projY;
  const perpDistanceMeters = Math.sqrt(dx * dx + dy * dy);

  const snappedLat = aLat + projY / metersPerDegLat;
  const snappedLng = aLng + projX / metersPerDegLng;

  return {
    snappedLat,
    snappedLng,
    perpDistanceMeters,
    fraction: t,
  };
}

/**
 * Snaps a live GPS coordinate onto an ordered polyline of route waypoints & stops.
 * Each point in `polylinePoints` has: { lat, lng, stopIndexFloat, isStop, stopIdx }
 * Returns exact continuous stop progress (e.g., 0.64), snapped coordinates,
 * and cross-track error (meters off the road) for detour detection.
 */
export function snapBusToRoutePolyline(lat, lng, polylinePoints, previousProgress = 0) {
  if (!polylinePoints || polylinePoints.length < 2) {
    return {
      progress: previousProgress,
      snappedLat: lat,
      snappedLng: lng,
      offRouteMeters: 0,
      closestStopIdx: Math.round(previousProgress),
    };
  }

  let bestScore = Infinity;
  let bestResult = null;

  for (let i = 0; i < polylinePoints.length - 1; i++) {
    const ptA = polylinePoints[i];
    const ptB = polylinePoints[i + 1];

    const proj = projectPointOntoSegment(lat, lng, ptA.lat, ptA.lng, ptB.lat, ptB.lng);

    const candidateProgress =
      ptA.stopIndexFloat + (ptB.stopIndexFloat - ptA.stopIndexFloat) * proj.fraction;

    // Directional continuity bias: penalize sudden backward jumps (> 0.35 stops)
    // unless the bus genuinely moved far along another segment.
    const backwardDelta = previousProgress - candidateProgress;
    const continuityPenalty = backwardDelta > 0.35 ? backwardDelta * 45 : 0;

    const score = proj.perpDistanceMeters + continuityPenalty;

    if (score < bestScore) {
      bestScore = score;
      bestResult = {
        progress: candidateProgress,
        snappedLat: proj.snappedLat,
        snappedLng: proj.snappedLng,
        offRouteMeters: proj.perpDistanceMeters,
        closestStopIdx: Math.floor(candidateProgress + 0.25), // 25% proximity threshold
      };
    }
  }

  return bestResult;
}

/**
 * Computes remaining path distance in meters along the ordered route stops
 * from the bus's current snapped coordinate to `targetStopIndex`.
 */
export function computeRemainingPathMeters(snappedLat, snappedLng, currentProgress, orderedStops, targetStopIndex) {
  const startNextIdx = Math.min(orderedStops.length - 1, Math.floor(currentProgress) + 1);
  if (targetStopIndex < startNextIdx) {
    // Bus is on the final segment approaching targetStopIndex
    const targetStop = orderedStops[targetStopIndex];
    return targetStop
      ? calculateHaversineDistance(snappedLat, snappedLng, targetStop.lat, targetStop.lng)
      : 0;
  }

  let totalMeters = 0;
  let prevLat = snappedLat;
  let prevLng = snappedLng;

  for (let i = startNextIdx; i <= targetStopIndex && i < orderedStops.length; i++) {
    const stop = orderedStops[i];
    totalMeters += calculateHaversineDistance(prevLat, prevLng, stop.lat, stop.lng);
    prevLat = stop.lat;
    prevLng = stop.lng;
  }

  return totalMeters;
}

/**
 * Computes Dynamic ETA in minutes using real speed, urban congestion floor,
 * and intermediate stop dwell times.
 */
export function computeDynamicETA({
  snappedLat,
  snappedLng,
  currentProgress,
  speedKmh,
  orderedStops,
  targetStopIndex,
  historicalSegmentSpeedMps = null,
}) {
  if (targetStopIndex <= currentProgress - 0.1) {
    return { etaMinutes: 0, remainingMeters: 0 };
  }

  const remainingMeters = computeRemainingPathMeters(
    snappedLat,
    snappedLng,
    currentProgress,
    orderedStops,
    targetStopIndex
  );

  // Urban Vijayapura bus speed bounds: fallback ~22 km/h (6.1 m/s) when stopped at signals
  const fallbackSpeedMps = historicalSegmentSpeedMps || 6.1;
  const liveSpeedMps = (speedKmh || 0) / 3.6;

  // Blend 65% live speed + 35% urban baseline when moving so sudden red lights don't spike ETA to 99 min
  const effectiveSpeedMps =
    liveSpeedMps >= 2.2 ? liveSpeedMps * 0.65 + fallbackSpeedMps * 0.35 : fallbackSpeedMps;

  const intermediateStopCount = Math.max(0, targetStopIndex - Math.ceil(currentProgress));
  const DWELL_TIME_PER_STOP_SEC = 35; // 35s average boarding/alighting pause

  const travelSeconds = remainingMeters / effectiveSpeedMps;
  const dwellSeconds = intermediateStopCount * DWELL_TIME_PER_STOP_SEC;

  const etaMinutes = Math.max(1, Math.ceil((travelSeconds + dwellSeconds) / 60));
  return {
    etaMinutes,
    remainingMeters: Math.round(remainingMeters),
  };
}

/**
 * Fuses multiple onboard passenger GPS reports using spatial median filtering
 * to reject outliers/spoofed coordinates when conductor GPS drops out.
 */
export function fusePassengerCrowdsourcedPings(pings) {
  if (!pings || pings.length === 0) return null;

  const lats = pings.map((p) => p.lat).sort((a, b) => a - b);
  const lngs = pings.map((p) => p.lng).sort((a, b) => a - b);
  const speeds = pings.map((p) => p.speed || 0).sort((a, b) => a - b);

  const mid = Math.floor(pings.length / 2);
  return {
    lat: lats[mid],
    lng: lngs[mid],
    speed: speeds[mid],
    contributorCount: pings.length,
  };
}