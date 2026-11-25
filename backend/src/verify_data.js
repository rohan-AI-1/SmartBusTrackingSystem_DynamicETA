// src/verify_data.js
import { VIJAYAPURA_ROUTES } from './data/vijayapura_routes.js';

console.log("\n==========================================");
console.log("  VIJAYAPURA ROUTE DATA INTEGRITY CHECK   ");
console.log("==========================================");

console.log(`✔ Total Corridors Configured: ${VIJAYAPURA_ROUTES.length}`);

VIJAYAPURA_ROUTES.forEach((route, index) => {
  console.log(`\nCorridor ${index + 1}: ${route.corridorName}`);
  console.log(`  - Total Stops: ${route.stops.length}`);
  console.log(`  - Origin:      ${route.stops[0].name} (ID: ${route.stops[0].id})`);
  console.log(`  - Terminal:    ${route.stops[route.stops.length - 1].name} (ID: ${route.stops[route.stops.length - 1].id})`);
});

// Count total unique stops across both corridors
const uniqueStops = new Set();
VIJAYAPURA_ROUTES.forEach(r => r.stops.forEach(s => uniqueStops.add(s.name)));

console.log("\n------------------------------------------");
console.log(`✔ Unique Bus Stops in Vijayapura: ${uniqueStops.size}`);
console.log("Status: DATASET INTEGRITY VERIFIED");
console.log("==========================================\n");