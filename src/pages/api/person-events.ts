import { NextApiRequest, NextApiResponse } from 'next';
import { Pool } from 'pg';

const pool = new Pool({
  user: process.env.PGUSER || 'registry_user',
  host: process.env.PGHOST || 'postgres',
  database: process.env.PGDATABASE || 'person_registry',
  password: process.env.PGPASSWORD || 'registry_pass',
  port: parseInt(process.env.PGPORT || '5432'),
});

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  const { id } = req.query;
  
  if (!id) {
    return res.status(400).json({ error: 'Person ID required' });
  }

  try {
    const result = await pool.query('SELECT * FROM person WHERE id = $1', [id]);
    const events = await pool.query(`
      SELECT e.*, ep.role 
      FROM event e 
      JOIN event_participant ep ON e.id = ep.event_id 
      WHERE ep.person_id = $1
    `, [id]);
    
    res.json({ person: result.rows[0], events: events.rows });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: 'Database error' });
  }
}