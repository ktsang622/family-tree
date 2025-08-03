import type { NextApiRequest, NextApiResponse } from 'next'
import { Client } from '@opensearch-project/opensearch'

// OpenSearch client setup
const osClient = new Client({
  node: process.env.OSHOST,
  auth: {
    username: 'admin',
    password: process.env.OPENSEARCH_ADMIN_PASSWORD!,
  },
})

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const {
    full_name,
    father_name,
    mother_name,
    spouse_name,
    child_name,
    dob,
    gender,
    identifier,
  } = req.body

  const must: any[] = []

  // Full name fuzzy/phonetic search
  if (full_name) {
    must.push({
      multi_match: {
        query: full_name,
        fields: ['full_name^2', 'full_name.phonetic', 'full_name.ngram'],
        fuzziness: 'AUTO',
      },
    })
  }

  // Optional filters
  if (dob) must.push({ match: { dob } })        // use match instead of term
  if (gender) must.push({ match: { gender } })

  // Add nested identifier match (optional but useful)
  if (identifier) {
    must.push({
      nested: {
        path: 'identifiers',
        query: {
          match: { 'identifiers.value': identifier },
        },
      },
    })
  }

  // Helper: Add nested family relationship query
  const addFamilyQuery = (role: string, name: string) => {
    must.push({
      nested: {
        path: 'linked_persons',
        query: {
          bool: {
            must: [
              { term: { 'linked_persons.role': role } },
              {
                multi_match: {
                  query: name,
                  fields: [
                    'linked_persons.full_name^2',
                    'linked_persons.full_name.phonetic',
                    'linked_persons.full_name.ngram',
                  ],
                  fuzziness: 'AUTO',
                },
              },
            ],
          },
        },
      },
    })
  }

  if (father_name) addFamilyQuery('father', father_name)
  if (mother_name) addFamilyQuery('mother', mother_name)
  if (spouse_name) addFamilyQuery('spouse', spouse_name)
  if (child_name) addFamilyQuery('child', child_name)

  // Prevent open-ended queries
  if (must.length === 0) {
    return res.status(400).json({ error: 'At least one field must be provided' })
  }

  try {
    const result = await osClient.search({
      index: process.env.PERSON_INDEX || 'person_index', // supports aliasing
      size: 20,
      body: {
        query: { bool: { must } },
      },
    })

    const hits = result.body?.hits?.hits?.map((hit: any) => ({
      ...hit._source,
      _score: hit._score,
    })) ?? []

    const total = typeof result.body.hits.total === 'object'
      ? result.body.hits.total.value
      : result.body.hits.total

    return res.status(200).json({ hits, total })
  } catch (err: any) {
    console.error('Advanced search error:', err)
    return res.status(500).json({
      error: 'Search failed',
      detail: err.message || err.toString(),
    })
  }
}
