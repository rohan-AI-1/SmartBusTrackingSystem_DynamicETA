// src/server.js
import express from 'express';
import http from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import crypto from 'crypto';
import dotenv from 'dotenv';
import nodemailer from 'nodemailer';

import pool from './config/cloud_db.js';
import { VIJAYAPURA_ROUTES } from './data/vijayapura_routes.js';
import {
  calculateHaversineDistance,
  snapBusToRoutePolyline,
  computeDynamicETA,
  fusePassengerCrowdsourcedPings,
} from './services/etaService.js';

dotenv.config();

const app = express();
const server = http.createServer(app);
const PORT = process.env.PORT || 5000;

app.use(cors());
app.use(express.json());

const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
});

// ================================================================
// 1. IN-MEMORY SPATIAL TRANSIT GRAPH & LIVE STATE
// ================================================================

const transitRoutes = new Map();
const activeTrips = new Map();
const passengerCrowdBeacons = new Map();
const issuedDigitalTickets = new Map();
let recentAnnouncements = [];

const KNOWN_DIVERSION_PROFILES = {
  SIDDESHWAR_FESTIVAL: {
    code: 'SIDDESHWAR_FESTIVAL',
    reason: 'Siddheshwar Gudi Festival Crowd',
    pathwayName: 'Station Road ➔ BLDEA Bypass ➔ Ring Road',
    rejoinStopName: 'Central Bus Stand',
    divertedStops: [
      'Railway Station',
      'BLDEA Cross (Diverted)',
      'Solapur Ring Road (Diverted)',
      'Central Bus Stand',
    ],
  },
  GOVT_ROADWORK: {
    code: 'GOVT_ROADWORK',
    reason: 'Smart City Road Work',
    pathwayName: 'M.G. Road ➔ Water Tank Bypass',
    rejoinStopName: 'Basaveshwar Circle',
    divertedStops: [
      'Central Bus Stand',
      'Water Tank Bypass (Diverted)',
      'KSRTC Depot Road (Diverted)',
      'Basaveshwar Circle',
    ],
  },
  STRIKE_BYPASS: {
    code: 'STRIKE_BYPASS',
    reason: 'Traffic Blockade / Strike',
    pathwayName: 'Outer Ring Highway Bypass',
    rejoinStopName: 'Athani Road Junction',
    divertedStops: [
      'Central Bus Stand',
      'Outer Ring Highway (Diverted)',
      'Athani Road Junction',
    ],
  },
};

// ================================================================
// 1B. TELEMETRY METRICS, RATE POLICING & AUTH
// ================================================================

const networkMetrics = {
  serverStartedAt: Date.now(),
  totalPacketsReceived: 0,
  outOfOrderPacketsDropped: 0,
  rateLimitedPacketsDropped: 0,
  staleSessionsReclaimed: 0,
  activeSocketConnections: 0,
};

const socketTokenBuckets = new Map();

function consumeRateLimitToken(socketId) {
  const now = Date.now();
  let bucket = socketTokenBuckets.get(socketId);
  if (!bucket) {
    bucket = { tokens: 6, lastRefill: now };
    socketTokenBuckets.set(socketId, bucket);
  }
  const elapsedSec = (now - bucket.lastRefill) / 1000;
  bucket.tokens = Math.min(6, bucket.tokens + elapsedSec * 3);
  bucket.lastRefill = now;

  if (bucket.tokens < 1) {
    networkMetrics.rateLimitedPacketsDropped++;
    return false;
  }
  bucket.tokens -= 1;
  return true;
}

const AUTH_SECRET = process.env.AUTH_SECRET || 'vijayapura-smart-bus-hmac-secret-2026';
const ADMIN_API_KEY = process.env.ADMIN_API_KEY || 'KKRTC_VJP_ADMIN_2026';

function issueConductorToken(callSign) {
  const payload = {
    callSign,
    exp: Date.now() + 18 * 60 * 60 * 1000,
  };
  const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = crypto.createHmac('sha256', AUTH_SECRET).update(encoded).digest('base64url');
  return `${encoded}.${sig}`;
}

function verifyConductorToken(token, expectedCallSign = null) {
  if (!token || typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;

  const [encoded, sig] = parts;
  const expectedSig = crypto.createHmac('sha256', AUTH_SECRET).update(encoded).digest('base64url');
  if (sig.length !== expectedSig.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expectedSig))) return null;

  try {
    const payload = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
    if (!payload.callSign || Date.now() > payload.exp) return null;
    if (expectedCallSign && payload.callSign !== expectedCallSign) return null;
    return payload;
  } catch {
    return null;
  }
}

function requireConductorAuth(req, res, next) {
  const authHeader = req.headers.authorization || '';
  const bearerToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : null;
  const targetCallSign = req.body?.callSign || null;

  const verified = verifyConductorToken(bearerToken, targetCallSign);
  if (!verified) {
    return res.status(401).json({
      success: false,
      error: 'Unauthorized: Valid conductor session token required.',
    });
  }
  req.conductor = verified;
  next();
}

const httpRateStore = new Map();
function createHttpRateLimiter(maxRequests, windowMs) {
  return (req, res, next) => {
    const ip = req.ip || req.socket?.remoteAddress || 'unknown';
    const key = `${req.path}:${ip}`;
    const now = Date.now();
    const timestamps = (httpRateStore.get(key) || []).filter((t) => now - t < windowMs);

    if (timestamps.length >= maxRequests) {
      return res.status(429).json({
        success: false,
        error: 'Too many requests. Please slow down and try again shortly.',
      });
    }
    timestamps.push(now);
    httpRateStore.set(key, timestamps);
    next();
  };
}

const normStop = (s) => (s || '').toLowerCase().replace(/[\s_-]+/g, '');

// ================================================================
// 1C. AI/ML MICROSERVICE CLIENT
// ================================================================

const ML_ENGINE_URL = (process.env.ML_ENGINE_URL || 'http://127.0.0.1:8001').replace(/\/+$/, '');

async function postToMlEngine(endpoint, payload, timeoutMs = 2500) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const resp = await fetch(`${ML_ENGINE_URL}${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return resp.ok ? await resp.json() : null;
  } catch {
    return null;
  }
}

async function runMlAnomalyCheck(trip, offRouteMeters) {
  const now = Date.now();
  if (now - (trip.lastMlCheckAt || 0) < 12000) return;
  trip.lastMlCheckAt = now;

  if (trip.speed < 2.0) {
    if (!trip.stationarySince) trip.stationarySince = now;
  } else {
    trip.stationarySince = null;
  }
  const stationarySeconds = trip.stationarySince ? (now - trip.stationarySince) / 1000 : 0;

  const result = await postToMlEngine('/detect/anomaly', {
    call_sign: trip.callSign,
    speed_kmh: trip.speed,
    off_route_meters: offRouteMeters,
    stationary_seconds: stationarySeconds,
    speed_variance: 2.5,
  });
  if (!result) return;

  if (result.is_anomaly && !trip.activeMlAlert) {
    trip.activeMlAlert = result.anomaly_type;
    io.emit('bus:ml_anomaly', {
      callSign: trip.callSign,
      corridorId: trip.corridorId,
      anomalyType: result.anomaly_type,
      anomalyScore: result.anomaly_score,
    });
  } else if (!result.is_anomaly && trip.activeMlAlert) {
    trip.activeMlAlert = null;
    io.emit('bus:ml_anomaly', {
      callSign: trip.callSign,
      corridorId: trip.corridorId,
      anomalyType: 'NORMAL',
      anomalyScore: result.anomaly_score,
    });
  }
}

function buildDirectionalPolylines(stops, waypoints) {
  const forwardPolyline = [];

  for (let i = 0; i < stops.length; i++) {
    forwardPolyline.push({
      lat: stops[i].lat,
      lng: stops[i].lng,
      stopIndexFloat: i,
      isStop: true,
      stopIdx: i,
    });

    if (i < stops.length - 1) {
      const nextStop = stops[i + 1];
      const segWaypoints = waypoints
        .filter((w) => w.from_stop_id === stops[i].id && w.to_stop_id === nextStop.id)
        .sort((a, b) => a.waypoint_order - b.waypoint_order);

      segWaypoints.forEach((wp, idx) => {
        const frac = (idx + 1) / (segWaypoints.length + 1);
        forwardPolyline.push({
          lat: Number(wp.lat),
          lng: Number(wp.lng),
          stopIndexFloat: i + frac,
          isStop: false,
          stopIdx: i,
        });
      });
    }
  }

  const maxIdx = stops.length - 1;
  const returnPolyline = [...forwardPolyline].reverse().map((pt) => ({
    ...pt,
    stopIndexFloat: maxIdx - pt.stopIndexFloat,
    stopIdx: maxIdx - pt.stopIdx,
  }));

  const returnStops = [...stops].reverse().map((s, idx) => ({ ...s, idx }));
  return { forwardPolyline, returnPolyline, returnStops };
}

function loadFallbackTransitGraph() {
  transitRoutes.clear();
  for (const r of VIJAYAPURA_ROUTES) {
    const forwardStops = r.stops.map((s, idx) => ({ ...s, idx }));
    const { forwardPolyline, returnPolyline, returnStops } = buildDirectionalPolylines(forwardStops, []);
    transitRoutes.set(r.corridorId, {
      corridorId: r.corridorId,
      corridorName: r.corridorName,
      terminalA: r.terminalA,
      terminalB: r.terminalB,
      forwardStops,
      returnStops,
      forwardPolyline,
      returnPolyline,
      detours: [],
    });
  }
  console.log('[TRANSIT GRAPH] Loaded fallback routes from vijayapura_routes.js');
}

async function hydrateTransitGraphFromCloud() {
  try {
    const [routesRes, routeStopsRes, waypointsRes, detoursRes] = await Promise.all([
      pool.query('SELECT id, name, terminal_a, terminal_b FROM routes ORDER BY id ASC'),
      pool.query(`
        SELECT rs.route_id, rs.sequence_order, s.id AS stop_id, s.name, s.lat, s.lng
        FROM route_stops rs
        JOIN stops s ON s.id = rs.stop_id
        ORDER BY rs.route_id ASC, rs.sequence_order ASC
      `),
      pool.query(`
        SELECT corridor_id, from_stop_id, to_stop_id, waypoint_order, lat, lng
        FROM route_waypoints
        ORDER BY corridor_id ASC, from_stop_id ASC, waypoint_order ASC
      `),
      pool.query('SELECT * FROM route_detours'),
    ]);

    transitRoutes.clear();

    if (routesRes.rows.length === 0) {
      loadFallbackTransitGraph();
    } else {
      for (const row of routesRes.rows) {
        const stopsForRoute = routeStopsRes.rows
          .filter((rs) => rs.route_id === row.id)
          .map((rs, idx) => ({
            idx,
            id: rs.stop_id,
            name: rs.name,
            lat: Number(rs.lat),
            lng: Number(rs.lng),
          }));

        const wpsForRoute = waypointsRes.rows.filter((w) => w.corridor_id === row.id);
        const detoursForRoute = detoursRes.rows.filter((d) => d.corridor_id === row.id);
        const { forwardPolyline, returnPolyline, returnStops } = buildDirectionalPolylines(
          stopsForRoute,
          wpsForRoute
        );

        transitRoutes.set(row.id, {
          corridorId: row.id,
          corridorName: row.name,
          terminalA: row.terminal_a,
          terminalB: row.terminal_b,
          forwardStops: stopsForRoute,
          returnStops,
          forwardPolyline,
          returnPolyline,
          detours: detoursForRoute,
        });
      }
      console.log(`[TRANSIT GRAPH] Hydrated ${transitRoutes.size} corridor(s) from Supabase PostgreSQL.`);
    }

    const activeRes = await pool.query(`SELECT * FROM active_trips WHERE status = 'ACTIVE'`);
    const now = Date.now();
    for (const row of activeRes.rows) {
      const route = transitRoutes.get(row.corridor_id) || transitRoutes.values().next().value;
      if (!route) continue;

      activeTrips.set(row.call_sign, {
        socketId: null,
        callSign: row.call_sign,
        corridorId: row.corridor_id,
        direction: row.direction || 'FORWARD',
        currentStopIndex: row.current_stop_index || 0,
        continuousProgress: Number(row.continuous_progress || 0),
        currentLat: Number(row.current_lat),
        currentLng: Number(row.current_lng),
        speed: Number(row.speed_kmh || 0),
        crowdLevel: row.crowd_level || 'SEATS',
        status: 'ACTIVE',
        hasReachedOrigin: true,
        isDetourActive: false,
        activeDetour: null,
        telemetrySource: 'CONDUCTOR_GPS',
        signalStatus: 'LIVE',
        lastSeq: -1,
        lastSeen: now,
        lastDbSync: now,
        stopArrivalTimestamps: {},
      });
    }
    if (activeRes.rows.length > 0) {
      console.log(`[CRASH RECOVERY] Restored ${activeRes.rows.length} active bus trip(s) from cloud.`);
    }

    const annRes = await pool.query(
      `SELECT id, corridor_id, conductor_call_sign, title, message, priority, created_at
       FROM announcements
       WHERE expires_at > NOW()
       ORDER BY created_at DESC LIMIT 25`
    );
    recentAnnouncements = annRes.rows;
  } catch (err) {
    console.error('[TRANSIT GRAPH HYDRATION ERROR]', err.message);
    if (transitRoutes.size === 0) loadFallbackTransitGraph();
  }
}

async function syncTripSnapshotToCloud(trip, force = false) {
  const now = Date.now();
  if (!force && now - (trip.lastDbSync || 0) < 8000) return;
  trip.lastDbSync = now;

  try {
    await pool.query(
      `INSERT INTO active_trips (
        call_sign, corridor_id, direction, current_lat, current_lng,
        current_stop_index, continuous_progress, speed_kmh, crowd_level, status, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'ACTIVE', NOW())
      ON CONFLICT (call_sign) DO UPDATE SET
        corridor_id = EXCLUDED.corridor_id,
        direction = EXCLUDED.direction,
        current_lat = EXCLUDED.current_lat,
        current_lng = EXCLUDED.current_lng,
        current_stop_index = EXCLUDED.current_stop_index,
        continuous_progress = EXCLUDED.continuous_progress,
        speed_kmh = EXCLUDED.speed_kmh,
        crowd_level = EXCLUDED.crowd_level,
        status = 'ACTIVE',
        updated_at = NOW()`,
      [
        trip.callSign,
        trip.corridorId,
        trip.direction,
        trip.currentLat,
        trip.currentLng,
        trip.currentStopIndex,
        trip.continuousProgress,
        trip.speed,
        trip.crowdLevel,
      ]
    );
  } catch (err) {
    console.error('[DB SYNC ERROR]', err.message);
  }
}

// ================================================================
// 2. EMAIL TRANSPORTER (GMAIL SMTP PORT 465 FOR CLOUD RELIABILITY)
// ================================================================

const transporter = nodemailer.createTransport({
  host: 'smtp.gmail.com',
  port: 465,
  secure: true,
  auth: {
    user: process.env.EMAIL_USER,
    pass: process.env.EMAIL_PASS,
  },
});

// ================================================================
// 3. CONDUCTOR AUTHENTICATION & REGISTRATION
// ================================================================

app.post('/api/auth/send-otp', async (req, res) => {
  const { email } = req.body;
  if (typeof email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
    return res.status(400).json({ success: false, error: 'A valid email is required.' });
  }

  const cleanEmail = email.trim().toLowerCase();

  try {
    const existing = await pool.query('SELECT call_sign FROM conductors WHERE email = $1', [cleanEmail]);
    if (existing.rows.length > 0) {
      return res.status(409).json({
        success: false,
        error: `This email is already registered under ID: ${existing.rows[0].call_sign}`,
      });
    }

    const otpCode = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000);

    await pool.query('DELETE FROM email_otps WHERE email = $1', [cleanEmail]);
    await pool.query(
      'INSERT INTO email_otps (email, otp_code, expires_at) VALUES ($1, $2, $3)',
      [cleanEmail, otpCode, expiresAt]
    );

    await transporter.sendMail({
      from: `"Vijayapura Smart Bus" <${process.env.EMAIL_USER}>`,
      to: cleanEmail,
      subject: `${otpCode} is your Conductor Verification Code`,
      html: `
        <div style="font-family: Arial, sans-serif; padding: 20px; border: 1px solid #e0e0e0; border-radius: 10px; max-width: 450px;">
          <h2 style="color: #C62828; margin-top: 0;">ವಿಜಯಪುರ ನಗರ ಸಾರಿಗೆ</h2>
          <p>Your Conductor Registration Verification Code is:</p>
          <div style="background: #FFF3E0; padding: 14px; text-align: center; border-radius: 8px; font-size: 28px; font-weight: bold; letter-spacing: 6px; color: #C62828;">
            ${otpCode}
          </div>
          <p style="font-size: 12px; color: #777; margin-top: 16px;">Valid for 5 minutes. Do not share this code.</p>
        </div>
      `,
    });

    return res.json({ success: true, message: 'Verification code sent to your email.' });
  } catch (err) {
    console.error('Send OTP Error:', err.message);
    return res.status(500).json({ success: false, error: 'Could not send verification code.' });
  }
});

app.post('/api/auth/verify-otp', async (req, res) => {
  const { email, otpCode } = req.body;
  if (typeof email !== 'string' || typeof otpCode !== 'string' || !email.trim() || !otpCode.trim()) {
    return res.status(400).json({ success: false, error: 'Email and OTP code are required.' });
  }

  const cleanEmail = email.trim().toLowerCase();

  try {
    const result = await pool.query(
      `SELECT id, expires_at FROM email_otps
       WHERE email = $1 AND otp_code = $2 AND verified = FALSE
       ORDER BY id DESC LIMIT 1`,
      [cleanEmail, otpCode.trim()]
    );

    if (result.rows.length === 0) {
      return res.status(400).json({ success: false, error: 'Invalid verification code.' });
    }

    const { id, expires_at } = result.rows[0];
    if (Date.now() > new Date(expires_at).getTime()) {
      return res.status(400).json({ success: false, error: 'Verification code has expired. Request a new one.' });
    }

    await pool.query('UPDATE email_otps SET verified = TRUE WHERE id = $1', [id]);
    return res.json({ success: true, message: 'Email verified successfully.' });
  } catch (err) {
    console.error('Verify OTP Error:', err);
    return res.status(500).json({ success: false, error: 'Error verifying code.' });
  }
});

app.post('/api/conductors/register', async (req, res) => {
  const { fullName, email } = req.body;
  if (typeof fullName !== 'string' || typeof email !== 'string' || !fullName.trim() || !email.trim()) {
    return res.status(400).json({ success: false, error: 'Name and email are required.' });
  }

  const cleanEmail = email.trim().toLowerCase();
  let client;

  try {
    client = await pool.connect();
    await client.query('BEGIN');

    const verifiedCheck = await client.query(
      'SELECT id FROM email_otps WHERE email = $1 AND verified = TRUE ORDER BY id DESC LIMIT 1 FOR UPDATE',
      [cleanEmail]
    );

    if (verifiedCheck.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(403).json({ success: false, error: 'Please verify your email before registering.' });
    }

    const dupCheck = await client.query('SELECT call_sign FROM conductors WHERE email = $1', [cleanEmail]);
    if (dupCheck.rows.length > 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({ success: false, error: `Already registered as ${dupCheck.rows[0].call_sign}` });
    }

    await client.query('LOCK TABLE conductors IN EXCLUSIVE MODE');

    const lastRow = await client.query('SELECT call_sign FROM conductors ORDER BY id DESC LIMIT 1');
    let nextCallSign = 'BUS100';

    if (lastRow.rows.length > 0) {
      const match = lastRow.rows[0].call_sign.match(/\d+/);
      const nextNum = match ? parseInt(match[0], 10) + 10 : 100;
      nextCallSign = `BUS${nextNum}`;
    }

    await client.query(
      `INSERT INTO conductors (call_sign, full_name, email, status) VALUES ($1, $2, $3, 'IDLE')`,
      [nextCallSign, fullName.trim(), cleanEmail]
    );

    await client.query('DELETE FROM email_otps WHERE email = $1', [cleanEmail]);
    await client.query('COMMIT');

    return res.json({ success: true, callSign: nextCallSign });
  } catch (err) {
    if (client) {
      try {
        await client.query('ROLLBACK');
      } catch {
        // Ignore rollback failure on broken connection
      }
    }
    console.error('Registration Error:', err);
    return res.status(500).json({ success: false, error: 'Database error during registration.' });
  } finally {
    if (client) client.release();
  }
});

app.post('/api/conductors/login', async (req, res) => {
  const { callSign } = req.body;
  if (typeof callSign !== 'string' || !callSign.trim()) {
    return res.status(400).json({ success: false, error: 'Conductor ID is required.' });
  }

  const normalizedId = callSign.toUpperCase().replace(/\s+/g, '');

  try {
    const result = await pool.query(
      `SELECT call_sign, full_name, status FROM conductors WHERE UPPER(REPLACE(call_sign, ' ', '')) = $1`,
      [normalizedId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({
        success: false,
        error: `Conductor ID "${callSign}" not found. Please register first.`,
      });
    }

    const conductor = result.rows[0];
    const existingTrip = activeTrips.get(conductor.call_sign) || null;
    const token = issueConductorToken(conductor.call_sign);

    return res.json({
      success: true,
      token,
      callSign: conductor.call_sign,
      fullName: conductor.full_name,
      activeTrip: existingTrip
        ? {
            corridorId: existingTrip.corridorId,
            direction: existingTrip.direction,
            crowdLevel: existingTrip.crowdLevel,
          }
        : null,
    });
  } catch (err) {
    console.error('Login Error:', err);
    return res.status(500).json({ success: false, error: 'Server error during login.' });
  }
});

// ================================================================
// 4. TRIP LIFECYCLE & METADATA APIS
// ================================================================

app.get('/health', (req, res) => {
  res.json({ status: 'OK', uptimeSeconds: Math.floor((Date.now() - networkMetrics.serverStartedAt) / 1000) });
});

app.post('/api/trips/stop', requireConductorAuth, async (req, res) => {
  const { callSign } = req.body;
  if (typeof callSign !== 'string' || !callSign.trim()) {
    return res.status(400).json({ success: false, error: 'Conductor ID is required.' });
  }

  try {
    const trip = activeTrips.get(callSign);
    activeTrips.delete(callSign);
    passengerCrowdBeacons.delete(callSign);

    await pool.query(`UPDATE active_trips SET status = 'COMPLETED', updated_at = NOW() WHERE call_sign = $1`, [
      callSign,
    ]);

    if (trip?.socketId) {
      io.to(trip.socketId).emit('conductor:trip_stopped', { callSign });
    }
    io.emit('bus:trip_ended', { callSign });

    return res.json({ success: true, message: 'Trip stopped successfully.' });
  } catch (err) {
    console.error('Trip stop error:', err);
    return res.status(500).json({ success: false, error: 'Could not stop trip.' });
  }
});

app.get('/api/network/metrics', (req, res) => {
  const transportBreakdown = { websocket: 0, polling: 0 };
  io.sockets.sockets.forEach((s) => {
    const t = s.conn?.transport?.name || 'unknown';
    if (t === 'websocket') transportBreakdown.websocket++;
    else transportBreakdown.polling++;
  });

  const activeLinks = Array.from(activeTrips.values()).map((t) => ({
    callSign: t.callSign,
    corridorId: t.corridorId,
    direction: t.direction,
    signalStatus: t.signalStatus || 'LIVE',
    lastSeq: t.lastSeq ?? -1,
    silenceMs: Date.now() - (t.lastSeen || Date.now()),
    telemetrySource: t.telemetrySource,
  }));

  return res.json({
    protocolArchitecture: {
      controlPlane: 'HTTP/1.1 REST (JSON)',
      dataPlane: 'RFC 6455 WebSocket (Socket.io Full-Duplex)',
      multicastModel: 'Topic/Corridor Room Pub-Sub',
      congestionControl: 'Token-Bucket Policer (6 burst / 3 pps) + Out-of-Order Seq Drop',
    },
    uptimeSeconds: Math.floor((Date.now() - networkMetrics.serverStartedAt) / 1000),
    activeSocketConnections: io.sockets.sockets.size,
    transportBreakdown,
    packetStats: {
      totalPacketsReceived: networkMetrics.totalPacketsReceived,
      outOfOrderPacketsDropped: networkMetrics.outOfOrderPacketsDropped,
      rateLimitedPacketsDropped: networkMetrics.rateLimitedPacketsDropped,
      staleSessionsReclaimed: networkMetrics.staleSessionsReclaimed,
    },
    activeLinks,
  });
});

app.get('/api/ml/status', async (req, res) => {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);
    const resp = await fetch(`${ML_ENGINE_URL}/health`, { signal: controller.signal });
    clearTimeout(timeout);
    const data = await resp.json();
    return res.json({ connected: true, ...data });
  } catch {
    return res.json({ connected: false, status: 'FALLBACK_KINEMATIC_MODE' });
  }
});

app.get('/api/ml/export-logs', async (req, res) => {
  const limit = Math.min(10000, Math.max(10, parseInt(req.query.limit || '2000', 10)));
  try {
    const result = await pool.query(
      `SELECT id, call_sign, corridor_id, lat, lng, speed_kmh, recorded_at
       FROM telemetry_logs
       ORDER BY recorded_at DESC
       LIMIT $1`,
      [limit]
    );
    return res.json({ count: result.rows.length, logs: result.rows });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

app.get('/api/corridors', (req, res) => {
  const corridors = Array.from(transitRoutes.values()).map((r) => ({
    corridorId: r.corridorId,
    corridorName: r.corridorName,
    terminalA: r.terminalA,
    terminalB: r.terminalB,
    stops: r.forwardStops.map((s) => s.name),
  }));
  return res.json({ corridors });
});

app.get('/api/stops', (req, res) => {
  const uniqueStops = new Set();
  transitRoutes.forEach((route) => {
    route.forwardStops.forEach((s) => uniqueStops.add(s.name));
  });
  return res.json({ stops: Array.from(uniqueStops).sort() });
});

// ================================================================
// 5. ANNOUNCEMENTS & ADMIN ROUTE SURVEY IMPORTER
// ================================================================

app.get('/api/announcements', async (req, res) => {
  const { corridorId, scope } = req.query;
  try {
    let queryText = `
      SELECT id, corridor_id, conductor_call_sign, title, message, priority, created_at
      FROM announcements
      WHERE expires_at > NOW()
    `;
    const params = [];

    if (scope === 'GENERAL') {
      queryText += ` AND corridor_id = 'ALL'`;
    } else if (scope === 'TARGETED' && corridorId) {
      queryText += ` AND corridor_id = $1`;
      params.push(corridorId);
    } else if (corridorId && corridorId !== 'ALL') {
      queryText += ` AND (corridor_id = 'ALL' OR corridor_id = $1)`;
      params.push(corridorId);
    }

    queryText += `
      ORDER BY
        CASE WHEN priority = 'URGENT' THEN 1 WHEN priority = 'ALERT' THEN 2 ELSE 3 END ASC,
        created_at DESC
      LIMIT 40
    `;

    const result = await pool.query(queryText, params);
    recentAnnouncements = result.rows;
    return res.json({ announcements: result.rows });
  } catch (err) {
    console.error('Fetch Announcements Error:', err);
    return res.status(500).json({ error: 'Could not load announcements.' });
  }
});

app.post('/api/announcements', createHttpRateLimiter(15, 60 * 1000), requireConductorAuth, async (req, res) => {
  const { corridorId = 'ALL', callSign, title, message, priority = 'INFO' } = req.body;
  if (!message || typeof message !== 'string' || !message.trim()) {
    return res.status(400).json({ success: false, error: 'Announcement message is required.' });
  }

  try {
    const cleanTitle = (title || (corridorId === 'ALL' ? 'City Transit Notice' : `${corridorId} Alert`)).trim();
    const resDb = await pool.query(
      `INSERT INTO announcements (corridor_id, conductor_call_sign, title, message, priority)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, corridor_id, conductor_call_sign, title, message, priority, created_at`,
      [corridorId, callSign || 'CONTROL_ROOM', cleanTitle, message.trim(), priority]
    );

    const created = resDb.rows[0];
    recentAnnouncements.unshift(created);
    if (recentAnnouncements.length > 30) recentAnnouncements.pop();

    io.emit('transit:announcement', created);
    return res.json({ success: true, announcement: created });
  } catch (err) {
    console.error('Announcement Error:', err);
    return res.status(500).json({ success: false, error: 'Could not publish announcement.' });
  }
});

app.delete('/api/announcements/:id', requireConductorAuth, async (req, res) => {
  const announcementId = parseInt(req.params.id, 10);
  const { callSign } = req.body || {};

  if (Number.isNaN(announcementId)) {
    return res.status(400).json({ success: false, error: 'Invalid announcement ID.' });
  }

  try {
    const check = await pool.query('SELECT conductor_call_sign FROM announcements WHERE id = $1', [announcementId]);
    if (check.rows.length === 0) {
      return res.json({ success: true, message: 'Already deleted.' });
    }

    const owner = check.rows[0].conductor_call_sign;
    if (callSign && owner && owner !== callSign) {
      return res.status(403).json({
        success: false,
        error: `Only ${owner} can delete this announcement for all passengers.`,
      });
    }

    await pool.query('DELETE FROM announcements WHERE id = $1', [announcementId]);
    recentAnnouncements = recentAnnouncements.filter((a) => a.id !== announcementId);

    io.emit('transit:announcement_deleted', { id: announcementId });
    return res.json({ success: true, message: 'Deleted for everyone.' });
  } catch (err) {
    console.error('Delete Announcement Error:', err);
    return res.status(500).json({ success: false, error: 'Could not delete announcement.' });
  }
});

app.post('/api/admin/import-survey', async (req, res) => {
  const providedKey = req.headers['x-admin-key'] || req.body?.adminKey;
  if (providedKey !== ADMIN_API_KEY) {
    return res.status(403).json({
      success: false,
      error: 'Forbidden: Valid x-admin-key header is required to import route surveys.',
    });
  }

  const { corridorId, corridorName, stops, breadcrumbs } = req.body || {};

  if (
    typeof corridorId !== 'string' ||
    typeof corridorName !== 'string' ||
    !corridorId.trim() ||
    !corridorName.trim() ||
    !Array.isArray(stops) ||
    stops.length < 2
  ) {
    return res.status(400).json({
      success: false,
      error: 'corridorId, corridorName, and at least 2 stops are required.',
    });
  }

  const invalidStop = stops.find(
    (stop) =>
      !stop ||
      typeof stop.name !== 'string' ||
      !stop.name.trim() ||
      !Number.isFinite(Number(stop.lat)) ||
      !Number.isFinite(Number(stop.lng)) ||
      Number(stop.lat) < -90 ||
      Number(stop.lat) > 90 ||
      Number(stop.lng) < -180 ||
      Number(stop.lng) > 180
  );
  if (invalidStop) {
    return res.status(400).json({
      success: false,
      error: 'Each stop must have a name, latitude, and longitude.',
    });
  }

  const cleanCorridorId = corridorId.trim().toUpperCase().replace(/\s+/g, '_');
  const terminalA = stops[0].name.trim();
  const terminalB = stops[stops.length - 1].name.trim();

  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');

    await client.query(
      `INSERT INTO routes (id, name, terminal_a, terminal_b)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET
         name = EXCLUDED.name,
         terminal_a = EXCLUDED.terminal_a,
         terminal_b = EXCLUDED.terminal_b`,
      [cleanCorridorId, corridorName.trim(), terminalA, terminalB]
    );

    await client.query('DELETE FROM route_stops WHERE route_id = $1', [cleanCorridorId]);
    await client.query('DELETE FROM route_waypoints WHERE corridor_id = $1', [cleanCorridorId]);

    const insertedStops = [];
    for (let i = 0; i < stops.length; i++) {
      const s = stops[i];
      const stopName = s.name.trim();
      const lat = Number(s.lat);
      const lng = Number(s.lng);

      let stopId;
      const existingStop = await client.query(
        'SELECT id FROM stops WHERE LOWER(TRIM(name)) = LOWER(TRIM($1)) LIMIT 1',
        [stopName]
      );

      if (existingStop.rows.length > 0) {
        stopId = existingStop.rows[0].id;
        await client.query('UPDATE stops SET lat = $1, lng = $2 WHERE id = $3', [lat, lng, stopId]);
      } else {
        const ins = await client.query('INSERT INTO stops (name, lat, lng) VALUES ($1, $2, $3) RETURNING id', [
          stopName,
          lat,
          lng,
        ]);
        stopId = ins.rows[0].id;
      }

      await client.query('INSERT INTO route_stops (route_id, stop_id, sequence_order) VALUES ($1, $2, $3)', [
        cleanCorridorId,
        stopId,
        i,
      ]);

      insertedStops.push({ id: stopId, name: stopName, lat, lng, index: i });
    }

    let waypointCount = 0;
    if (Array.isArray(breadcrumbs) && breadcrumbs.length > 0) {
      for (let i = 0; i < insertedStops.length - 1; i++) {
        const fromStop = insertedStops[i];
        const toStop = insertedStops[i + 1];
        const segPoints = breadcrumbs.filter((b) => Number(b.afterStopIndex) === i);

        for (let w = 0; w < segPoints.length; w++) {
          await client.query(
            `INSERT INTO route_waypoints (corridor_id, from_stop_id, to_stop_id, waypoint_order, lat, lng)
             VALUES ($1, $2, $3, $4, $5, $6)`,
            [cleanCorridorId, fromStop.id, toStop.id, w + 1, Number(segPoints[w].lat), Number(segPoints[w].lng)]
          );
          waypointCount++;
        }
      }
    }

    await client.query('COMMIT');
    await hydrateTransitGraphFromCloud();

    return res.json({
      success: true,
      corridorId: cleanCorridorId,
      stopsSaved: insertedStops.length,
      waypointsSaved: waypointCount,
    });
  } catch (err) {
    if (client) {
      try {
        await client.query('ROLLBACK');
      } catch {
        // Ignore rollback failure on broken connection
      }
    }
    console.error('Survey Import Error:', err);
    return res.status(500).json({ success: false, error: err.message });
  } finally {
    if (client) client.release();
  }
});

// ================================================================
// 5C. RUSH-HOUR DIGITAL TICKETING & STUDENT PASS VERIFICATION
// ================================================================

app.post('/api/tickets/issue', createHttpRateLimiter(20, 60 * 1000), (req, res) => {
  const { callSign, pickupStop, destinationStop, distanceMeters = 2000 } = req.body || {};
  if (!callSign || !pickupStop || !destinationStop) {
    return res.status(400).json({ success: false, error: 'Bus ID, pickup stop, and destination stop are required.' });
  }

  const km = Math.max(0.5, Number(distanceMeters) / 1000);
  const fareInr = Math.min(35, Math.max(10, 10 + Math.floor(km / 2) * 5));
  const code = crypto.randomBytes(3).toString('hex').toUpperCase();
  const issuedAt = Date.now();
  const expiresAt = issuedAt + 90 * 60 * 1000;

  const rawPayload = `${code}|${callSign}|${pickupStop}|${destinationStop}|${fareInr}|${expiresAt}`;
  const signature = crypto
    .createHmac('sha256', AUTH_SECRET)
    .update(rawPayload)
    .digest('hex')
    .slice(0, 12)
    .toUpperCase();

  const ticket = {
    code,
    signature,
    callSign,
    pickupStop,
    destinationStop,
    fareInr,
    issuedAt,
    expiresAt,
    verified: false,
  };
  issuedDigitalTickets.set(code, ticket);

  return res.json({ success: true, ticket });
});

app.post('/api/tickets/verify', requireConductorAuth, (req, res) => {
  const { callSign, codeOrPassId } = req.body || {};
  if (!codeOrPassId || typeof codeOrPassId !== 'string') {
    return res.status(400).json({ success: false, error: 'Ticket code or Student Pass ID is required.' });
  }

  const cleanInput = codeOrPassId.trim().toUpperCase();

  if (cleanInput.startsWith('STU-') || cleanInput.startsWith('PASS-')) {
    if (cleanInput.length < 7) {
      return res.status(400).json({ success: false, valid: false, error: 'Invalid Student Pass ID format.' });
    }
    return res.json({
      success: true,
      valid: true,
      type: 'STUDENT_PASS',
      passId: cleanInput,
      message: `Valid KKRTC Student Pass (${cleanInput}) — Zero Fare`,
    });
  }

  const ticket = issuedDigitalTickets.get(cleanInput);
  if (!ticket) {
    return res.status(404).json({ success: false, valid: false, error: 'Ticket code not found.' });
  }
  if (callSign && ticket.callSign !== callSign) {
    return res.status(400).json({
      success: false,
      valid: false,
      error: `Ticket belongs to ${ticket.callSign}, not ${callSign}.`,
    });
  }
  if (Date.now() > ticket.expiresAt) {
    return res.status(400).json({ success: false, valid: false, error: 'Ticket has expired.' });
  }
  if (ticket.verified) {
    return res.status(409).json({
      success: false,
      valid: false,
      error: `Ticket ${cleanInput} was ALREADY verified!`,
    });
  }

  ticket.verified = true;
  ticket.verifiedAt = Date.now();

  return res.json({
    success: true,
    valid: true,
    type: 'DIGITAL_TICKET',
    ticket,
    message: `PAID ₹${ticket.fareInr} • ${ticket.pickupStop} ➔ ${ticket.destinationStop}`,
  });
});

// ================================================================
// 6. 3-TIER INTELLIGENT PASSENGER SEARCH ENGINE
// ================================================================

app.get('/api/search', async (req, res) => {
  const { startStop, endStop } = req.query;

  if (!startStop || !endStop) {
    return res.status(400).json({ error: 'Both startStop and endStop are required.' });
  }

  const startNorm = normStop(startStop);
  const endNorm = normStop(endStop);

  if (startNorm === endNorm) {
    return res.status(400).json({ error: 'Source and destination stops cannot be the same.' });
  }

  const directIncomingBuses = [];
  const recentlyPassedBuses = [];

  for (const route of transitRoutes.values()) {
    const fwdStart = route.forwardStops.findIndex((s) => normStop(s.name) === startNorm);
    const fwdEnd = route.forwardStops.findIndex((s) => normStop(s.name) === endNorm);

    let searchedDirection = null;
    let orderedStops = null;
    let startIdx = -1;
    let endIdx = -1;

    if (fwdStart !== -1 && fwdEnd !== -1 && fwdStart < fwdEnd) {
      searchedDirection = 'FORWARD';
      orderedStops = route.forwardStops;
      startIdx = fwdStart;
      endIdx = fwdEnd;
    } else {
      const retStart = route.returnStops.findIndex((s) => normStop(s.name) === startNorm);
      const retEnd = route.returnStops.findIndex((s) => normStop(s.name) === endNorm);
      if (retStart !== -1 && retEnd !== -1 && retStart < retEnd) {
        searchedDirection = 'RETURN';
        orderedStops = route.returnStops;
        startIdx = retStart;
        endIdx = retEnd;
      }
    }

    if (!searchedDirection) continue;

    for (const trip of activeTrips.values()) {
      if (trip.status !== 'ACTIVE' || trip.corridorId !== route.corridorId || trip.direction !== searchedDirection) {
        continue;
      }

      const currentIdx = Math.max(0, Math.min(orderedStops.length - 1, trip.currentStopIndex));
      const nextIdx = Math.min(orderedStops.length - 1, currentIdx + 1);

      let passengerJourneyMeters = 0;
      for (let i = startIdx; i < endIdx; i++) {
        passengerJourneyMeters += calculateHaversineDistance(
          orderedStops[i].lat,
          orderedStops[i].lng,
          orderedStops[i + 1].lat,
          orderedStops[i + 1].lng
        );
      }

      if (trip.continuousProgress <= startIdx + 0.15) {
        const { etaMinutes: fallbackEta, remainingMeters } = computeDynamicETA({
          snappedLat: trip.currentLat,
          snappedLng: trip.currentLng,
          currentProgress: trip.continuousProgress,
          speedKmh: trip.speed,
          orderedStops,
          targetStopIndex: startIdx,
        });

        const stopsRemaining = Math.max(0, startIdx - Math.floor(trip.continuousProgress));
        const mlPred = await postToMlEngine('/predict/eta', {
          remaining_meters: remainingMeters,
          remaining_stops: stopsRemaining,
          current_speed_kmh: trip.speed,
        });

        directIncomingBuses.push({
          matchType: 'DIRECT_INCOMING',
          callSign: trip.callSign,
          corridorId: trip.corridorId,
          corridorName: route.corridorName,
          direction: trip.direction,
          orderedStopNames: orderedStops.map((s) => s.name),
          currentStop: orderedStops[currentIdx].name,
          nextStop: orderedStops[nextIdx].name,
          pickupStop: orderedStops[startIdx].name,
          destinationStop: orderedStops[endIdx].name,
          etaMinutes: mlPred ? mlPred.eta_minutes : fallbackEta,
          etaEngine: mlPred ? `${mlPred.model} (${mlPred.traffic_regime})` : 'KINEMATIC_FALLBACK',
          mlAnomalyType: trip.activeMlAlert || 'NORMAL',
          remainingMetersToPickup: remainingMeters,
          passengerJourneyMeters: Math.round(passengerJourneyMeters),
          crowdLevel: trip.crowdLevel || 'SEATS',
          telemetrySource: trip.telemetrySource || 'CONDUCTOR_GPS',
          currentLat: trip.currentLat,
          currentLng: trip.currentLng,
        });
      } else if (trip.continuousProgress > startIdx + 0.15 && trip.continuousProgress < endIdx - 0.1) {
        const stopsPast = trip.continuousProgress - startIdx;
        if (stopsPast <= 2.5) {
          const distPastMeters = Math.round(
            calculateHaversineDistance(
              orderedStops[startIdx].lat,
              orderedStops[startIdx].lng,
              trip.currentLat,
              trip.currentLng
            )
          );

          if (distPastMeters <= 1200) {
            const passedMinutesAgo = Math.max(1, Math.round(distPastMeters / 300));
            recentlyPassedBuses.push({
              matchType: 'RECENTLY_PASSED',
              callSign: trip.callSign,
              corridorId: trip.corridorId,
              corridorName: route.corridorName,
              direction: trip.direction,
              orderedStopNames: orderedStops.map((s) => s.name),
              currentStop: orderedStops[currentIdx].name,
              nextStop: orderedStops[nextIdx].name,
              pickupStop: orderedStops[startIdx].name,
              destinationStop: orderedStops[endIdx].name,
              passedStopsAgo: Math.max(1, Math.round(stopsPast)),
              passedMetersAgo: distPastMeters,
              passedMinutesAgo,
              catchableAdvice: `Passed ${orderedStops[startIdx].name} ~${passedMinutesAgo} min ago (${distPastMeters}m ahead). Heading toward ${orderedStops[nextIdx].name}.`,
              passengerJourneyMeters: Math.round(passengerJourneyMeters),
              crowdLevel: trip.crowdLevel || 'SEATS',
              currentLat: trip.currentLat,
              currentLng: trip.currentLng,
            });
          }
        }
      }
    }
  }

  directIncomingBuses.sort((a, b) => a.etaMinutes - b.etaMinutes);
  recentlyPassedBuses.sort((a, b) => a.passedMetersAgo - b.passedMetersAgo);

  const transferSuggestions = [];
  if (directIncomingBuses.length === 0) {
    transitRoutes.forEach((routeA) => {
      transitRoutes.forEach((routeB) => {
        if (routeA.corridorId === routeB.corridorId) return;

        const dirsA = [
          { dir: 'FORWARD', stops: routeA.forwardStops },
          { dir: 'RETURN', stops: routeA.returnStops },
        ];
        const dirsB = [
          { dir: 'FORWARD', stops: routeB.forwardStops },
          { dir: 'RETURN', stops: routeB.returnStops },
        ];

        for (const dA of dirsA) {
          const sIdx = dA.stops.findIndex((s) => normStop(s.name) === startNorm);
          if (sIdx === -1) continue;

          for (const dB of dirsB) {
            const eIdx = dB.stops.findIndex((s) => normStop(s.name) === endNorm);
            if (eIdx === -1) continue;

            for (let i = sIdx + 1; i < dA.stops.length; i++) {
              const candidateInterchange = dA.stops[i];
              const j = dB.stops.findIndex((s) => normStop(s.name) === normStop(candidateInterchange.name));
              if (j !== -1 && j < eIdx) {
                transferSuggestions.push({
                  matchType: 'TRANSFER_SUGGESTION',
                  firstLeg: {
                    corridorId: routeA.corridorId,
                    corridorName: routeA.corridorName,
                    direction: dA.dir,
                    fromStop: dA.stops[sIdx].name,
                    alighAtStop: candidateInterchange.name,
                  },
                  secondLeg: {
                    corridorId: routeB.corridorId,
                    corridorName: routeB.corridorName,
                    direction: dB.dir,
                    boardAtStop: candidateInterchange.name,
                    toStop: dB.stops[eIdx].name,
                  },
                  summary: `Take ${routeA.corridorName} (${dA.dir}) to ${candidateInterchange.name}, then transfer to ${routeB.corridorName} (${dB.dir}) toward ${dB.stops[eIdx].name}.`,
                });
                break;
              }
            }
          }
        }
      });
    });
  }

  return res.json({
    buses: directIncomingBuses,
    recentlyPassedBuses,
    transferSuggestions,
  });
});

// ================================================================
// 7. CORE TELEMETRY PROCESSOR
// ================================================================

function processBusTelemetryUpdate(trip, rawLat, rawLng, rawSpeed, sourceLabel = 'CONDUCTOR_GPS') {
  const route = transitRoutes.get(trip.corridorId) || transitRoutes.values().next().value;
  if (!route) return;

  const orderedStops = trip.direction === 'FORWARD' ? route.forwardStops : route.returnStops;
  const polyline = trip.direction === 'FORWARD' ? route.forwardPolyline : route.returnPolyline;

  if (!trip.hasReachedOrigin && orderedStops.length > 0) {
    const distToOrigin = calculateHaversineDistance(rawLat, rawLng, orderedStops[0].lat, orderedStops[0].lng);
    if (distToOrigin <= 60) {
      trip.hasReachedOrigin = true;
      trip.stopArrivalTimestamps[0] = Date.now();
    }
  }

  const snapped = snapBusToRoutePolyline(rawLat, rawLng, polyline, trip.continuousProgress);

  trip.currentLat = snapped.snappedLat;
  trip.currentLng = snapped.snappedLng;
  trip.speed = typeof rawSpeed === 'number' ? Math.max(0, rawSpeed) : 0;
  trip.continuousProgress = snapped.progress;
  trip.currentStopIndex = Math.max(0, Math.min(orderedStops.length - 1, snapped.closestStopIdx));
  trip.telemetrySource = sourceLabel;
  trip.lastSeen = Date.now();

  if (!trip.stopArrivalTimestamps[trip.currentStopIndex]) {
    const arrivalNow = Date.now();
    trip.stopArrivalTimestamps[trip.currentStopIndex] = arrivalNow;

    const prevIdx = trip.currentStopIndex - 1;
    if (prevIdx >= 0 && trip.stopArrivalTimestamps[prevIdx]) {
      const elapsedSec = (arrivalNow - trip.stopArrivalTimestamps[prevIdx]) / 1000;
      const fromStop = orderedStops[prevIdx];
      const toStop = orderedStops[trip.currentStopIndex];
      const segDist = calculateHaversineDistance(fromStop.lat, fromStop.lng, toStop.lat, toStop.lng);

      if (elapsedSec > 8 && segDist > 40) {
        const segSpeedKmh = Number(((segDist / 1000) / (elapsedSec / 3600)).toFixed(2));
        pool
          .query('INSERT INTO telemetry_logs (call_sign, corridor_id, lat, lng, speed_kmh) VALUES ($1, $2, $3, $4, $5)', [
            trip.callSign,
            trip.corridorId,
            toStop.lat,
            toStop.lng,
            segSpeedKmh,
          ])
          .catch(() => {});

        postToMlEngine('/train/segment', {
          corridor_id: trip.corridorId,
          direction: trip.direction,
          from_stop: fromStop.name,
          to_stop: toStop.name,
          distance_meters: segDist,
          elapsed_seconds: elapsedSec,
        });
      }
    }
  }

  if (snapped.offRouteMeters > 90) {
    if (!trip.isDetourActive) {
      const dbDetour = route.detours?.[0];
      const fallbackProfile = KNOWN_DIVERSION_PROFILES.SIDDESHWAR_FESTIVAL;
      const detourPayload = dbDetour
        ? {
            pathway_name: dbDetour.pathway_name,
            rejoin_stop_name: dbDetour.rejoin_stop_name,
            reason: 'Traffic / Road Diversion',
            diverted_stops: fallbackProfile.divertedStops,
          }
        : {
            pathway_name: fallbackProfile.pathwayName,
            rejoin_stop_name: fallbackProfile.rejoinStopName,
            reason: fallbackProfile.reason,
            diverted_stops: fallbackProfile.divertedStops,
          };

      trip.isDetourActive = true;
      trip.activeDetour = detourPayload;
      io.emit('bus:detour_alert', {
        callSign: trip.callSign,
        isDetourActive: true,
        reason: detourPayload.reason,
        pathwayName: detourPayload.pathway_name,
        rejoinStopName: detourPayload.rejoin_stop_name,
        divertedStops: detourPayload.diverted_stops,
      });
    }
  } else if (trip.isDetourActive && snapped.offRouteMeters <= 45) {
    trip.isDetourActive = false;
    trip.activeDetour = null;
    io.emit('bus:detour_alert', {
      callSign: trip.callSign,
      isDetourActive: false,
      reason: '',
      pathwayName: '',
      rejoinStopName: '',
      divertedStops: [],
    });
  }

  const terminalStop = orderedStops[orderedStops.length - 1];
  const distToTerminal = calculateHaversineDistance(rawLat, rawLng, terminalStop.lat, terminalStop.lng);

  if (trip.currentStopIndex === orderedStops.length - 1 && distToTerminal <= 45) {
    trip.direction = trip.direction === 'FORWARD' ? 'RETURN' : 'FORWARD';
    trip.currentStopIndex = 0;
    trip.continuousProgress = 0.0;
    trip.stopArrivalTimestamps = { 0: Date.now() };
  }

  const updatedStops = trip.direction === 'FORWARD' ? route.forwardStops : route.returnStops;
  io.emit('bus:telemetry_stream', {
    callSign: trip.callSign,
    corridorId: trip.corridorId,
    direction: trip.direction,
    lat: trip.currentLat,
    lng: trip.currentLng,
    speed: trip.speed,
    currentStopIndex: trip.currentStopIndex,
    currentStopName: updatedStops[trip.currentStopIndex]?.name || '',
    nextStopName: updatedStops[Math.min(updatedStops.length - 1, trip.currentStopIndex + 1)]?.name || '',
    progress: trip.continuousProgress,
    hasReachedOrigin: trip.hasReachedOrigin,
    crowdLevel: trip.crowdLevel,
    mlAnomalyType: trip.activeMlAlert || 'NORMAL',
    telemetrySource: trip.telemetrySource,
    orderedStops: updatedStops.map((s) => ({ name: s.name, lat: s.lat, lng: s.lng })),
  });

  runMlAnomalyCheck(trip, snapped.offRouteMeters);
  evaluateCorridorHeadway(trip);
  trackStopDwellAndSurge(trip, orderedStops);
  evaluateInterchangeConnections(trip, orderedStops);

  const logNow = Date.now();
  if (logNow - (trip.lastTelemetryLogAt || 0) >= 10000) {
    trip.lastTelemetryLogAt = logNow;
    pool
      .query('INSERT INTO telemetry_logs (call_sign, corridor_id, lat, lng, speed_kmh) VALUES ($1, $2, $3, $4, $5)', [
        trip.callSign,
        trip.corridorId,
        rawLat,
        rawLng,
        Number((trip.speed || 0).toFixed(2)),
      ])
      .catch(() => {});
  }

  syncTripSnapshotToCloud(trip, false);
}

function trackStopDwellAndSurge(trip, orderedStops) {
  const currentStopObj = orderedStops[trip.currentStopIndex];
  if (!currentStopObj) return;

  const distToStop = calculateHaversineDistance(
    trip.currentLat,
    trip.currentLng,
    currentStopObj.lat,
    currentStopObj.lng
  );
  const now = Date.now();

  if (distToStop <= 45 && trip.speed < 4.0) {
    if (!trip.activeDwell) {
      trip.activeDwell = { stopName: currentStopObj.name, startedAt: now };
    }
    return;
  }

  if (trip.activeDwell && (distToStop > 55 || trip.speed >= 6.0)) {
    const dwellSeconds = (now - trip.activeDwell.startedAt) / 1000;
    const stopName = trip.activeDwell.stopName;
    trip.activeDwell = null;

    if (dwellSeconds >= 10 && dwellSeconds <= 600) {
      postToMlEngine('/train/dwell', {
        stop_name: stopName,
        crowd_level: trip.crowdLevel || 'SEATS',
        dwell_seconds: dwellSeconds,
      }).then((resData) => {
        if (resData?.is_surge) {
          io.emit('bus:stop_surge', {
            callSign: trip.callSign,
            corridorId: trip.corridorId,
            stopName,
            dwellSeconds: Math.round(dwellSeconds),
            extraDelayMin: resData.extra_delay_min || 1,
          });
        }
      });
    }
  }
}

function evaluateInterchangeConnections(arrivingTrip, orderedStops) {
  const now = Date.now();
  if (now - (arrivingTrip.lastTransferCheckAt || 0) < 20000) return;
  arrivingTrip.lastTransferCheckAt = now;

  const nextStop = orderedStops[Math.min(orderedStops.length - 1, arrivingTrip.currentStopIndex + 1)];
  if (!nextStop) return;

  const distToHub = calculateHaversineDistance(
    arrivingTrip.currentLat,
    arrivingTrip.currentLng,
    nextStop.lat,
    nextStop.lng
  );
  if (distToHub > 350 || distToHub < 40) return;

  const hubNorm = normStop(nextStop.name);

  for (const otherTrip of activeTrips.values()) {
    if (
      otherTrip.status !== 'ACTIVE' ||
      otherTrip.callSign === arrivingTrip.callSign ||
      otherTrip.corridorId === arrivingTrip.corridorId
    ) {
      continue;
    }

    const otherRoute = transitRoutes.get(otherTrip.corridorId);
    if (!otherRoute) continue;

    const otherStops = otherTrip.direction === 'FORWARD' ? otherRoute.forwardStops : otherRoute.returnStops;
    const otherCurrentStop = otherStops[otherTrip.currentStopIndex];
    if (!otherCurrentStop || normStop(otherCurrentStop.name) !== hubNorm) continue;

    if (otherTrip.speed < 5.0 && otherTrip.socketId) {
      io.to(otherTrip.socketId).emit('conductor:transfer_hold', {
        callSign: otherTrip.callSign,
        hubStop: nextStop.name,
        arrivingCallSign: arrivingTrip.callSign,
        arrivingDistanceMeters: Math.round(distToHub),
        holdSeconds: 45,
        message: `Transfer Sync: ${arrivingTrip.callSign} is ${Math.round(distToHub)}m from ${nextStop.name}. Hold 45s for connecting passengers.`,
      });
    }
  }
}

async function evaluateCorridorHeadway(currentTrip) {
  const now = Date.now();
  if (now - (currentTrip.lastHeadwayCheckAt || 0) < 15000) return;
  currentTrip.lastHeadwayCheckAt = now;

  const peers = Array.from(activeTrips.values())
    .filter(
      (t) =>
        t.status === 'ACTIVE' &&
        t.corridorId === currentTrip.corridorId &&
        t.direction === currentTrip.direction
    )
    .sort((a, b) => a.continuousProgress - b.continuousProgress);

  const idx = peers.findIndex((t) => t.callSign === currentTrip.callSign);
  if (idx === -1 || idx === peers.length - 1) {
    if (currentTrip.activeHeadwayAlert) {
      currentTrip.activeHeadwayAlert = null;
      if (currentTrip.socketId) {
        io.to(currentTrip.socketId).emit('conductor:headway_advice', {
          callSign: currentTrip.callSign,
          isBunching: false,
          advice: '',
          holdSeconds: 0,
        });
      }
    }
    return;
  }

  const leadBus = peers[idx + 1];
  const stopGap = Math.max(0, leadBus.continuousProgress - currentTrip.continuousProgress);
  const distMeters = calculateHaversineDistance(
    currentTrip.currentLat,
    currentTrip.currentLng,
    leadBus.currentLat,
    leadBus.currentLng
  );

  const hw = await postToMlEngine('/predict/headway', {
    corridor_id: currentTrip.corridorId,
    direction: currentTrip.direction,
    lead_call_sign: leadBus.callSign,
    trail_call_sign: currentTrip.callSign,
    stop_gap: stopGap,
    distance_meters: distMeters,
    trail_speed_kmh: currentTrip.speed,
  });
  if (!hw) return;

  if (hw.is_bunching) {
    currentTrip.activeHeadwayAlert = hw.advice;
    if (currentTrip.socketId) {
      io.to(currentTrip.socketId).emit('conductor:headway_advice', {
        callSign: currentTrip.callSign,
        leadCallSign: leadBus.callSign,
        isBunching: true,
        headwayMinutes: hw.estimated_headway_min,
        holdSeconds: hw.recommended_hold_seconds,
        advice: hw.advice,
      });
    }
  } else if (currentTrip.activeHeadwayAlert) {
    currentTrip.activeHeadwayAlert = null;
    if (currentTrip.socketId) {
      io.to(currentTrip.socketId).emit('conductor:headway_advice', {
        callSign: currentTrip.callSign,
        isBunching: false,
        advice: '',
        holdSeconds: 0,
      });
    }
  }
}

// ================================================================
// 8. SOCKET.IO REAL-TIME ENGINE
// ================================================================

io.on('connection', (socket) => {
  networkMetrics.activeSocketConnections = io.sockets.sockets.size;

  socket.on('network:ping', (payload, ack) => {
    if (typeof ack === 'function') {
      ack({
        serverTime: Date.now(),
        clientSentAt: payload?.clientSentAt || Date.now(),
        transport: socket.conn?.transport?.name || 'unknown',
      });
    }
  });

  socket.on('conductor:start_trip', async (data) => {
    const { callSign, corridorId, token } = data || {};
    if (typeof callSign !== 'string' || !callSign.trim()) {
      socket.emit('conductor:trip_error', { error: 'Valid conductor ID required.' });
      return;
    }
    if (!verifyConductorToken(token, callSign)) {
      socket.emit('conductor:trip_error', { error: 'Unauthorized: Invalid or expired conductor token.' });
      return;
    }

    const chosenCorridor = corridorId || 'CORRIDOR_1';
    const route = transitRoutes.get(chosenCorridor) || transitRoutes.values().next().value;
    const originStop = route?.forwardStops?.[0] || { lat: 16.792655, lng: 75.722467, name: 'Origin' };

    try {
      let trip = activeTrips.get(callSign);
      if (trip && trip.corridorId === chosenCorridor && trip.status === 'ACTIVE') {
        trip.socketId = socket.id;
        trip.signalStatus = 'LIVE';
        trip.lastSeen = Date.now();
        socket.emit('conductor:trip_confirmed', { callSign, corridorId: chosenCorridor, resumed: true });
        return;
      }

      trip = {
        socketId: socket.id,
        callSign,
        corridorId: chosenCorridor,
        direction: 'FORWARD',
        currentStopIndex: 0,
        continuousProgress: 0.0,
        currentLat: originStop.lat,
        currentLng: originStop.lng,
        speed: 0,
        crowdLevel: 'SEATS',
        status: 'ACTIVE',
        hasReachedOrigin: false,
        isDetourActive: false,
        activeDetour: null,
        telemetrySource: 'CONDUCTOR_GPS',
        signalStatus: 'LIVE',
        lastSeq: -1,
        lastSeen: Date.now(),
        lastDbSync: 0,
        stopArrivalTimestamps: {},
      };

      activeTrips.set(callSign, trip);
      await syncTripSnapshotToCloud(trip, true);

      socket.emit('conductor:trip_confirmed', { callSign, corridorId: chosenCorridor, resumed: false });
    } catch (err) {
      console.error('Trip start error:', err);
      socket.emit('conductor:trip_error', { error: 'Could not start trip.' });
    }
  });

  socket.on('conductor:telemetry', (data) => {
    networkMetrics.totalPacketsReceived++;
    if (!consumeRateLimitToken(socket.id)) return;

    const { callSign, lat, lng, speed, seq, token } = data || {};
    if (!callSign || typeof lat !== 'number' || typeof lng !== 'number') return;
    if (!verifyConductorToken(token, callSign)) return;

    const trip = activeTrips.get(callSign);
    if (!trip) return;

    if (typeof seq === 'number') {
      if (seq <= trip.lastSeq) {
        networkMetrics.outOfOrderPacketsDropped++;
        return;
      }
      trip.lastSeq = seq;
    }

    if (trip.signalStatus !== 'LIVE') {
      trip.signalStatus = 'LIVE';
      io.emit('bus:signal_status', { callSign, signalStatus: 'LIVE', silenceSeconds: 0 });
    }

    trip.socketId = socket.id;
    processBusTelemetryUpdate(trip, lat, lng, speed, 'CONDUCTOR_GPS');
  });

  socket.on('conductor:manual_stop_checkin', (data) => {
    const { callSign, stopIndex, token } = data || {};
    if (!verifyConductorToken(token, callSign)) return;
    const trip = activeTrips.get(callSign);
    if (!trip || typeof stopIndex !== 'number') return;

    const route = transitRoutes.get(trip.corridorId);
    if (!route) return;

    const orderedStops = trip.direction === 'FORWARD' ? route.forwardStops : route.returnStops;
    const targetStop = orderedStops[stopIndex];
    if (!targetStop) return;

    trip.hasReachedOrigin = true;
    processBusTelemetryUpdate(trip, targetStop.lat, targetStop.lng, 15, 'CONDUCTOR_MANUAL_CHECKIN');
  });

  socket.on('conductor:crowd_status', (data) => {
    const { callSign, crowdLevel, token } = data || {};
    if (!verifyConductorToken(token, callSign)) return;
    const trip = activeTrips.get(callSign);
    if (!trip || !['SEATS', 'STANDING', 'FULL'].includes(crowdLevel)) return;

    trip.crowdLevel = crowdLevel;
    io.emit('bus:crowd_updated', { callSign, crowdLevel });
    syncTripSnapshotToCloud(trip, true);
  });

  socket.on('conductor:set_diversion', (data) => {
    const { callSign, profileCode, token } = data || {};
    if (!verifyConductorToken(token, callSign)) return;
    const trip = activeTrips.get(callSign);
    if (!trip) return;

    if (!profileCode || profileCode === 'NONE') {
      trip.isDetourActive = false;
      trip.activeDetour = null;
      io.emit('bus:detour_alert', {
        callSign,
        isDetourActive: false,
        reason: '',
        pathwayName: '',
        rejoinStopName: '',
        divertedStops: [],
      });
      return;
    }

    const profile = KNOWN_DIVERSION_PROFILES[profileCode] || KNOWN_DIVERSION_PROFILES.GOVT_ROADWORK;
    trip.isDetourActive = true;
    trip.activeDetour = {
      pathway_name: profile.pathwayName,
      rejoin_stop_name: profile.rejoinStopName,
      reason: profile.reason,
      diverted_stops: profile.divertedStops,
    };

    io.emit('bus:detour_alert', {
      callSign,
      isDetourActive: true,
      reason: profile.reason,
      pathwayName: profile.pathwayName,
      rejoinStopName: profile.rejoinStopName,
      divertedStops: profile.divertedStops,
    });
  });

  socket.on('passenger:telemetry', (data) => {
    const { callSign, lat, lng, speed } = data || {};
    if (!callSign || typeof lat !== 'number' || typeof lng !== 'number') return;

    const trip = activeTrips.get(callSign);
    if (!trip || trip.status !== 'ACTIVE') return;

    const distFromBus = calculateHaversineDistance(lat, lng, trip.currentLat, trip.currentLng);
    if (distFromBus > 150) return;

    if (distFromBus <= 120 && !socket.data?.promptedOnboardFor?.has(callSign)) {
      socket.data.promptedOnboardFor = socket.data.promptedOnboardFor || new Set();
      socket.data.promptedOnboardFor.add(callSign);
      socket.emit('passenger:confirm_onboard', {
        callSign,
        distanceMeters: Math.round(distFromBus),
        currentCrowdLevel: trip.crowdLevel || 'SEATS',
      });
    }

    if (!passengerCrowdBeacons.has(callSign)) {
      passengerCrowdBeacons.set(callSign, new Map());
    }
    const beacons = passengerCrowdBeacons.get(callSign);
    const now = Date.now();
    beacons.set(socket.id, { lat, lng, speed: speed || 0, updatedAt: now });

    for (const [sid, ping] of beacons.entries()) {
      if (now - ping.updatedAt > 20000) beacons.delete(sid);
    }

    if (now - (trip.lastSeen || 0) > 12000 && beacons.size > 0) {
      const fused = fusePassengerCrowdsourcedPings(Array.from(beacons.values()));
      if (fused) {
        processBusTelemetryUpdate(trip, fused.lat, fused.lng, fused.speed, 'PASSENGER_CROWDSOURCED');
      }
    }
  });

  socket.on('passenger:crowd_vote', (data) => {
    const { callSign, crowdLevel, lat, lng } = data || {};
    if (!callSign || !['SEATS', 'STANDING', 'FULL'].includes(crowdLevel)) return;

    const trip = activeTrips.get(callSign);
    if (!trip || trip.status !== 'ACTIVE') return;

    if (typeof lat === 'number' && typeof lng === 'number') {
      const dist = calculateHaversineDistance(lat, lng, trip.currentLat, trip.currentLng);
      if (dist > 180) return;
    }

    const now = Date.now();
    trip.passengerCrowdVotes = trip.passengerCrowdVotes || new Map();
    trip.passengerCrowdVotes.set(socket.id, { level: crowdLevel, updatedAt: now });

    const tally = { SEATS: 0, STANDING: 0, FULL: 0 };
    for (const [sid, vote] of trip.passengerCrowdVotes.entries()) {
      if (now - vote.updatedAt > 10 * 60 * 1000) {
        trip.passengerCrowdVotes.delete(sid);
      } else {
        tally[vote.level] = (tally[vote.level] || 0) + 1;
      }
    }

    let winningLevel = trip.crowdLevel;
    let maxVotes = 0;
    for (const [lvl, count] of Object.entries(tally)) {
      if (count > maxVotes) {
        maxVotes = count;
        winningLevel = lvl;
      }
    }

    if (maxVotes >= 1 && winningLevel !== trip.crowdLevel) {
      trip.crowdLevel = winningLevel;
      io.emit('bus:crowd_updated', {
        callSign,
        crowdLevel: winningLevel,
        source: 'PASSENGER_CONSENSUS',
        voteCount: maxVotes,
      });
      syncTripSnapshotToCloud(trip, true);
    }
  });

  socket.on('trip:get_live_state', (data) => {
    const trip = activeTrips.get(data?.callSign);
    if (!trip) return;

    const route = transitRoutes.get(trip.corridorId);
    const updatedStops = route
      ? trip.direction === 'FORWARD'
        ? route.forwardStops
        : route.returnStops
      : [];

    socket.emit('bus:telemetry_stream', {
      callSign: trip.callSign,
      corridorId: trip.corridorId,
      direction: trip.direction,
      lat: trip.currentLat,
      lng: trip.currentLng,
      speed: trip.speed,
      currentStopIndex: trip.currentStopIndex,
      currentStopName: updatedStops[trip.currentStopIndex]?.name || '',
      nextStopName: updatedStops[Math.min(updatedStops.length - 1, trip.currentStopIndex + 1)]?.name || '',
      progress: trip.continuousProgress,
      hasReachedOrigin: trip.hasReachedOrigin,
      crowdLevel: trip.crowdLevel,
      mlAnomalyType: trip.activeMlAlert || 'NORMAL',
      telemetrySource: trip.telemetrySource,
      orderedStops: updatedStops.map((s) => ({ name: s.name, lat: s.lat, lng: s.lng })),
    });
  });

  socket.on('disconnect', () => {
    networkMetrics.activeSocketConnections = io.sockets.sockets.size;
    socketTokenBuckets.delete(socket.id);
    passengerCrowdBeacons.forEach((beacons) => beacons.delete(socket.id));
  });
});

// ================================================================
// 8B. HEARTBEAT WATCHDOG & MEMORY CLEANUP (30s TICK)
// ================================================================

const WEAK_LINK_THRESHOLD_MS = 90 * 1000;
const DEAD_PEER_TIMEOUT_MS = 5 * 60 * 1000;

setInterval(async () => {
  const now = Date.now();

  for (const [callSign, trip] of activeTrips.entries()) {
    const silenceMs = now - (trip.lastSeen || now);

    if (silenceMs >= DEAD_PEER_TIMEOUT_MS) {
      activeTrips.delete(callSign);
      passengerCrowdBeacons.delete(callSign);
      networkMetrics.staleSessionsReclaimed++;

      try {
        await pool.query(
          `UPDATE active_trips SET status = 'AUTO_EXPIRED', updated_at = NOW() WHERE call_sign = $1`,
          [callSign]
        );
      } catch (err) {
        console.error('[WATCHDOG DB ERROR]', err.message);
      }

      io.emit('bus:trip_ended', { callSign, reason: 'DEAD_PEER_TIMEOUT' });
    } else if (silenceMs >= WEAK_LINK_THRESHOLD_MS && trip.signalStatus !== 'WEAK') {
      trip.signalStatus = 'WEAK';
      io.emit('bus:signal_status', {
        callSign,
        signalStatus: 'WEAK',
        silenceSeconds: Math.round(silenceMs / 1000),
      });
    }
  }

  for (const [code, ticket] of issuedDigitalTickets.entries()) {
    if (now > ticket.expiresAt) issuedDigitalTickets.delete(code);
  }

  for (const [key, timestamps] of httpRateStore.entries()) {
    const fresh = timestamps.filter((t) => now - t < 60 * 1000);
    if (fresh.length === 0) httpRateStore.delete(key);
    else httpRateStore.set(key, fresh);
  }
}, 30 * 1000);

// ================================================================
// 9. SERVER BOOTSTRAP
// ================================================================

hydrateTransitGraphFromCloud().then(() => {
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`SMART BUS TRANSIT SERVER RUNNING | PORT: ${PORT} | CORRIDORS: ${transitRoutes.size}`);
  });
});

server.on('error', (err) => {
  console.error('[SERVER ERROR]', err);
});