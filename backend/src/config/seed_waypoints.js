// src/config/seed_waypoints.js
import pool from './cloud_db.js';
import { VIJAYAPURA_ROUTES } from '../data/vijayapura_routes.js';

async function seedIntermediateWaypoints() {
  console.log("\n========================================================");
  console.log(" POPULATING 4-POINT STREET WAYPOINTS IN CLOUD DB ");
  console.log("========================================================");

  try {
    const client = await pool.connect();
    let totalWaypoints = 0;

    for (const route of VIJAYAPURA_ROUTES) {
      for (let i = 0; i < route.stops.length - 1; i++) {
        const fromStop = route.stops[i];
        const toStop = route.stops[i + 1];

        // Generate 4 intermediate coordinates at 20%, 40%, 60%, 80% along the road
        for (let step = 1; step <= 4; step++) {
          const ratio = step / 5.0;
          const intermediateLat = fromStop.lat + (toStop.lat - fromStop.lat) * ratio;
          const intermediateLng = fromStop.lng + (toStop.lng - fromStop.lng) * ratio;

          await client.query(
            `INSERT INTO route_waypoints (corridor_id, from_stop_id, to_stop_id, waypoint_order, lat, lng)
             VALUES ($1, $2, $3, $4, $5, $6)`,
            [route.corridorId, fromStop.id, toStop.id, step, intermediateLat, intermediateLng]
          );
          totalWaypoints++;
        }
      }
    }

    console.log(`✔ Generated & Stored ${totalWaypoints} High-Precision Street Waypoints in Supabase!`);
    console.log("Status: EXCEPTION 2 WAYPOINTS REGISTERED");
    console.log("========================================================\n");

    client.release();
    process.exit(0);
  } catch (err) {
    console.error("Waypoint Seeding Error:", err.message);
    process.exit(1);
  }
}

seedIntermediateWaypoints();