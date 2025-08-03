// src/lib/db.ts
import { Pool } from 'pg';

const pool = new Pool({
  user: process.env.PGUSER,
  host: process.env.PGHOST,
  database: process.env.PGDATABASE,
  password: process.env.PGPASSWORD,
  port: parseInt(process.env.PGPORT || '5432'),
});

console.log("🔌 PostgreSQL pool created");

export async function query(sql: string, params: any[] = []) {
  let client;
  try {
    client = await pool.connect();
    console.log("✅ DB connection established");
    console.log("📘 SQL:", sql);
    console.log("📘 Params:", params);

    const res = await client.query(sql, params);

    console.log("✅ Query success, rows:", res.rowCount);
    return res.rows;
  } catch (err) {
    console.error("❌ DB Query Error:", err);
    throw err;
  } finally {
    if (client) {
      client.release();
      console.log("🔁 DB client released");
    }
  }
}
