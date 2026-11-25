// src/config/cloud_db.js
import pg from 'pg';
import dotenv from 'dotenv';

dotenv.config();

const { Pool } = pg;

// Use explicit parameters (Bypasses URL parser errors completely)
const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '6543'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  ssl: {
    rejectUnauthorized: false
  }
});

pool.on('connect', () => {
  console.log('[CLOUD DB] Connected securely to 24/7 Supabase PostgreSQL');
});

pool.on('error', (err) => {
  console.error('[CLOUD DB ERROR] Connection error:', err.message);
});

export default pool;