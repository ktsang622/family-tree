import type { NextApiRequest, NextApiResponse } from 'next'
import { Client } from '@opensearch-project/opensearch'
import { Pool } from 'pg'

// Validate OpenSearch host
const osHost = process.env.OSHOST
if (!osHost?.startsWith('http')) {
  throw new Error(`Invalid OSHOST: ${osHost}`)
}
console.log('OpenSearch URL:', osHost)

// OpenSearch client
const osClient = new Client({
  node: osHost,
  auth: {
    username: 'admin',
    password: process.env.OPENSEARCH_ADMIN_PASSWORD || 'WelcomeDemo1.23@',
  },
})

// PostgreSQL pool
const pgPool = new Pool({
  user: process.env.PGUSER,
  host: process.env.PGHOST,
  database: process.env.PGDATABASE,
  password: process.env.PGPASSWORD,
  port: parseInt(process.env.PGPORT || '5432'),
})

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  try {
    const pgClient = await pgPool.connect()

    const result = await pgClient.query(`
      SELECT 
        fl.person_id,
        json_agg(
          json_build_object(
            'role', fl.relationship_type,
            'person_id', rp.id,
            'full_name', rp.full_name
          )
        ) AS linked_persons
      FROM family_link fl
      JOIN person rp ON rp.id = fl.related_person_id
      WHERE fl.relationship_type IN ('mother', 'father', 'spouse', 'child')
      GROUP BY fl.person_id
    `)

    const updates = result.rows.flatMap((row) => [
      { update: { _index: 'person_index_v2', _id: row.person_id } },
      { doc: { linked_persons: row.linked_persons || [] } },
    ])

    const response = await osClient.bulk({ refresh: true, body: updates })

    pgClient.release()
    res.status(200).json({ result: 'linked persons indexed', updated: response.body.items.length })
  } catch (error) {
    console.error(error)
    res.status(500).json({ error: 'Indexing failed', detail: `${error}` })
  }
}
