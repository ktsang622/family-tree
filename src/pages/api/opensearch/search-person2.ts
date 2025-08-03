import type { NextApiRequest, NextApiResponse } from 'next'
import { Client } from '@opensearch-project/opensearch'
import { subYears, formatISO } from 'date-fns'

const osHost = process.env.OSHOST
if (!osHost?.startsWith('http')) {
  throw new Error(`Invalid OSHOST: ${osHost}`)
}

const osClient = new Client({
  node: osHost,
  auth: {
    username: 'admin',
    password: process.env.OPENSEARCH_ADMIN_PASSWORD || 'WelcomeDemo1.23@',
  },
})

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const {
    page = 1,
    pageSize = 10,
    given_name,
    family_name,
    full_name,
    gender,
    dob,
    age,
    identifier,
  } = req.body

  if (!given_name && !family_name && !full_name && !gender && !dob && !identifier) {
    return res.status(400).json({ error: 'At least one field must be provided' })
  }

  try {
    const must: any[] = []
    const should: any[] = []

    // Prioritize individual names with higher boost
    if (given_name) {
      should.push({
        multi_match: {
          query: given_name,
          fields: ['given_name.keyword^5', 'given_name^3', 'given_name.phonetic^2'],
          fuzziness: 'AUTO',
        },
      })
    }

    if (family_name) {
      should.push({
        multi_match: {
          query: family_name,
          fields: ['family_name.keyword^5', 'family_name^3', 'family_name.phonetic^2'],
          fuzziness: 'AUTO',
        },
      })
    }

    if (full_name) {
      should.push({
        multi_match: {
          query: full_name,
          fields: ['full_name^3', 'full_name.keyword^2', 'full_name.ngram^1.5', 'full_name.phonetic'],
          fuzziness: 'AUTO',
        },
      })
    }

    if (should.length > 0) {
      must.push({
        bool: {
          should,
          minimum_should_match: 1,
        },
      })
    }

    if (gender) {
      must.push({ term: { gender: gender.toLowerCase() } })
    }

    if (dob) {
      must.push({ term: { dob } })
    } else if (age) {
      const ageInt = parseInt(age)
      if (!isNaN(ageInt)) {
        const today = new Date()
        const dobUpper = formatISO(subYears(today, ageInt))
        const dobLower = formatISO(subYears(today, ageInt + 1))
        must.push({
          range: {
            dob: {
              gte: dobLower,
              lt: dobUpper,
            },
          },
        })
      }
    }

    if (identifier) {
      must.push({
        nested: {
          path: 'identifiers',
          query: {
            bool: {
              should: [{ term: { 'identifiers.value': identifier } }],
            },
          },
        },
      })
    }

    const from = (parseInt(page) - 1) * parseInt(pageSize)

    const result = await osClient.search({
      index: 'person_index',
      from,
      size: parseInt(pageSize),
      track_total_hits: true,
      body: {
        query: {
          bool: { must },
        },
      },
    })

    const total =
      typeof result.body.hits.total === 'object'
        ? result.body.hits.total.value
        : result.body.hits.total

    const hits = result.body?.hits?.hits?.map((hit: any) => ({
      ...hit._source,
      _score: hit._score,
    }))

    res.status(200).json({ hits, total })
  } catch (err: any) {
    console.error('Search error:', err)
    res.status(500).json({ error: 'Search failed', detail: err.message || err.toString() })
  }
}

