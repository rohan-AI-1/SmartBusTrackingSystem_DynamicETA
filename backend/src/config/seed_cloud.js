// src/config/seed_cloud.js
import pool from './cloud_db.js';
import { VIJAYAPURA_ROUTES } from '../data/vijayapura_routes.js';

async function seedCloudDatabase() {
  console.log("\n========================================================");
  console.log(" UPLOADING VIJAYAPURA DATA TO 24/7 CLOUD DATABASE ");
  console.log("========================================================");

  try {
    const client = await pool.connect();

    // 1. Insert Routes
    for (const route of VIJAYAPURA_ROUTES) {
      await client.query(
        `INSERT INTO routes (id, name, terminal_a, terminal_b)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name`,
        [route.corridorId, route.corridorName, route.terminalA, route.terminalB]
      );

      // 2. Insert Stops & Route Stop Mappings
      for (let i = 0; i < route.stops.length; i++) {
        const stop = route.stops[i];

        // Insert or update stop
        const stopRes = await client.query(
          `INSERT INTO stops (id, name, lat, lng)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (name) DO UPDATE SET lat = EXCLUDED.lat, lng = EXCLUDED.lng
           RETURNING id`,
          [stop.id, stop.name, stop.lat, stop.lng]
        );

        const stopId = stopRes.rows[0].id;

        // Map sequence to route
        await client.query(
          `INSERT INTO route_stops (route_id, stop_id, sequence_order)
           VALUES ($1, $2, $3)
           ON CONFLICT (route_id, sequence_order) DO UPDATE SET stop_id = EXCLUDED.stop_id`,
          [route.corridorId, stopId, i + 1]
        );
      }
    }

    console.log("✔ Routes Seeded: 2 Master Corridors stored in Cloud");
    console.log("✔ Stops Seeded:  All Vijayapura Stops Stored in Cloud");
    console.log("Status: CLOUD DATABASE IS FULLY POPULATED & READY");
    console.log("========================================================\n");

    client.release();
    process.exit(0);
  } catch (error) {
    console.error("Cloud Seeding Error:", error);
    process.exit(1);
  }
}

seedCloudDatabase();