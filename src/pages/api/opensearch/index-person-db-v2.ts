import type { NextApiRequest, NextApiResponse } from 'next'
import { Client } from '@opensearch-project/opensearch'
import { Pool } from 'pg'

// Validate OpenSearch host
const osHost = process.env.OSHOST
if (!osHost?.startsWith('http')) {
  throw new Error(`Invalid OSHOST: ${osHost}`)
}

// OpenSearch client
const osClient = new Client({
  node: osHost,
  auth: {
    username: 'admin',
    password: process.env.OPENSEARCH_ADMIN_PASSWORD || 'WelcomeDemo1.23@',
  },
})

// PostgreSQL connection pool
const pgPool = new Pool({
  user: process.env.PGUSER,
  host: process.env.PGHOST,
  database: process.env.PGDATABASE,
  password: process.env.PGPASSWORD,
  port: parseInt(process.env.PGPORT || '5432'),
})

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  const pageSize = 500
  let offset = 0
  let totalIndexed = 0
  let totalErrors = 0

  try {
    const pgClient = await pgPool.connect()

    while (true) {
      const result = await pgClient.query('SELECT * FROM person ORDER BY id LIMIT $1 OFFSET $2', [pageSize, offset])
      const persons = result.rows
      if (persons.length === 0) break

      const bulkOps = persons.flatMap((person) => [
        { index: { _index: 'person_index_v2', _id: person.id } },
        {
          ...sanitizePerson(person),
          age: person.dob ? calculateAge(person.dob) : null,
        },
      ])

      for (let i = 0; i < bulkOps.length; i += 1000) {
        const chunk = bulkOps.slice(i, i + 1000)
        const response = await osClient.bulk({ refresh: false, body: chunk })

        if (response.body.errors) {
          const failedItems = response.body.items.filter((item: any) => item.index?.error)
          totalErrors += failedItems.length
          failedItems.forEach((item: any) => {
            console.error('❌ Index error:', item.index.error)
          })
        }
      }

      totalIndexed += persons.length
      offset += pageSize
    }

    await osClient.indices.refresh({ index: 'person_index_v2' })
    pgClient.release()

    res.status(200).json({ result: 'success', indexed: totalIndexed, errors: totalErrors })
  } catch (error: any) {
    console.error('🔥 Indexing failed:', error)
    res.status(500).json({
      error: 'Indexing failed',
      detail: error instanceof Error ? error.message : String(error),
    })
  }
}

function sanitizePerson(person: any) {
  return {
    ...person,
    identifiers: safeJson(person.identifiers),
    dob: person.dob || null,
    gender: person.gender?.toLowerCase() || null,
  }
}

function safeJson(value: any): any[] {
  try {
    return typeof value === 'string' ? JSON.parse(value) : value || []
  } catch {
    return []
  }
}

function calculateAge(dob: string): number {
  const birth = new Date(dob)
  const now = new Date()
  const ageMs = now.getTime() - birth.getTime()
  return Math.floor(ageMs / (1000 * 60 * 60 * 24 * 365.25))
}

