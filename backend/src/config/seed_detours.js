// src/config/seed_detours.js
import pool from './cloud_db.js';

async function seedDetourPathways() {
  console.log("\n========================================================");
  console.log(" SEEDING VIJAYAPURA DETOUR PATHWAYS IN CLOUD DB ");
  console.log("========================================================");

  try {
    const client = await pool.connect();

    // 1. Gandhi Chowk Bypass (Rejoins at Shivaji Circle)
    const detourId = "DETOUR_GANDHI_CHOWK_BYPASS";
    const corridorId = "CORRIDOR_1";
    const pathwayName = "Station Bypass Road";
    const rejoinStop = "Shivaji Circle";

    // Optional turn points where driver can enter the bypass
    const optionalTurns = [
      { lat: 16.8280, lng: 75.7110, turnName: "Darbar School Turn" },
      { lat: 16.8275, lng: 75.7100, turnName: "Market Corner Cut" }
    ];

    // Coordinates along the bypass road
    const bypassCoords = [
      { lat: 16.8280, lng: 75.7110 },
      { lat: 16.8290, lng: 75.7090 }, // Moving along bypass
      { lat: 16.8270, lng: 75.7060 }, // Parallel to Gandhi Chowk
      { lat: 16.8255, lng: 75.7050 }  // Rejoining Shivaji Circle
    ];

    await client.query(
      `INSERT INTO route_detours (id, corridor_id, pathway_name, rejoin_stop_name, optional_turns, pathway_coordinates)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (id) DO UPDATE 
       SET pathway_name = EXCLUDED.pathway_name, optional_turns = EXCLUDED.optional_turns`,
      [detourId, corridorId, pathwayName, rejoinStop, JSON.stringify(optionalTurns), JSON.stringify(bypassCoords)]
    );

    console.log(`✔ Registered Detour Pathway: "${pathwayName}" (Rejoins at: ${rejoinStop})`);
    console.log("Status: DETOUR PATHWAY STORED IN SUPABASE");
    console.log("========================================================\n");

    client.release();
    process.exit(0);
  } catch (err) {
    console.error("Detour Seeding Error:", err.message);
    process.exit(1);
  }
}

seedDetourPathways();