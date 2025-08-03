import type { NextApiRequest, NextApiResponse } from 'next'
import { Client } from '@opensearch-project/opensearch'
import { Pool } from 'pg'

// Validate OSHOST
const osHost = process.env.OSHOST
if (!osHost?.startsWith('http')) {
  throw new Error(`Invalid OSHOST: ${osHost}`)
} else {
  console.log('OpenSearch URL:', osHost)
}

// OpenSearch client
const osClient = new Client({
  node: osHost,
  auth: {
    username: 'admin',
    password: process.env.OPENSEARCH_ADMIN_PASSWORD || 'WelcomeDemo1.23@'
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
    const result = await pgClient.query('SELECT * FROM person')
    const persons = result.rows

    const bulkOps = persons.flatMap((person) => [
      { index: { _index: 'person_index_v2', _id: person.id } },
      {
        ...person,
        age: person.dob ? calculateAge(person.dob) : null,
      },
    ])

    const response = await osClient.bulk({ refresh: true, body: bulkOps })

    pgClient.release()
    res.status(200).json({ result: 'success', items: response.body.items })
  } catch (error) {
    console.error(error)
    res.status(500).json({ error: 'Indexing failed', detail: `${error}` })
  }
}

function calculateAge(dob: string) {
  const birth = new Date(dob)
  const ageDifMs = Date.now() - birth.getTime()
  return Math.floor(ageDifMs / (1000 * 60 * 60 * 24 * 365.25))
}
