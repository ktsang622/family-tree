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
    full_name,
    gender,
    dob,
    age,
    identifier,
    searchMode = 'relaxer',
  } = req.body

  if (!full_name && !gender && !dob && !identifier) {
    return res.status(400).json({ error: 'At least one field must be provided' })
  }

  try {
    const must: any[] = []

    // Handle full_name search modes
    if (full_name) {

      if (searchMode === 'strict') {
  // Exact phrase on keywords only
  must.push({
    multi_match: {
      query: full_name,
      fields: ['full_name.keyword^3', 'given_name.keyword', 'family_name.keyword'],
      type: 'phrase',
    },
  });
} else if (searchMode === 'relaxer') {
  // Moderate fuzziness + phonetic without wildcard
  must.push({
    bool: {
      should: [
        {
          multi_match: {
            query: full_name,
            type: 'most_fields',
            fields: [
              'full_name^3',
              'full_name.keyword^2',
              'full_name.ngram^2.5',
              'given_name^2',
              'family_name^2',
            ],
            fuzziness: 1,
          },
        },
	{
	  match_phrase_prefix: {
	    "full_name": {
	      "query": full_name,
	      "boost": 5
	    }
	  }
	},
        {
          multi_match: {
            query: full_name,
            type: 'best_fields',
            fields: [
              'full_name.phonetic^4',
              'given_name.phonetic^2',
              'family_name.phonetic^2',
            ],
            operator: 'or',
          },
        },
      ],
      minimum_should_match: 1,
    },
  });
} else {
  // most_relaxed = relaxer + wildcard for substring + boost wildcard
  must.push({
    bool: {
      should: [
        {
          multi_match: {
            query: full_name,
            type: 'most_fields',
            fields: [
              'full_name^3',
              'full_name.keyword^2',
              'full_name.ngram^2',
              'given_name^2',
              'family_name^2',
            ],
            fuzziness: 'AUTO',
          },
        },
        {
          multi_match: {
            query: full_name,
            type: 'best_fields',
            fields: [
              'full_name.phonetic^6',
              'given_name.phonetic^3',
              'family_name.phonetic^3',
            ],
            operator: 'and',
          },
        },
        {
	  bool: {
	    should: [
		{

          wildcard: {
            'full_name.keyword': {
		value: `*${full_name.toLowerCase()}*`,
	    	boost: 30
	    },
          },
        },
	{
          wildcard: {
            'given_name.keyword': {
	  	value: `*${full_name.toLowerCase()}*`,
	    	boost: 30
	    },
          },
	},
	{
          wildcard: {
            'family_name.keyword': {
		value: `*${full_name.toLowerCase()}*`,
	        boost: 30
	    },
          },
	},
      ],
      minimum_should_match: 1,
    },
	},
      ],
   minimum_should_match: 1,
    },
  });
}

/*


      if (searchMode === 'strict') {
        // Strict exact phrase match on keyword fields
        must.push({
          multi_match: {
            query: full_name,
            fields: ['full_name.keyword^3', 'given_name.keyword', 'family_name.keyword'],
            type: 'phrase',
          },
        })
      } else {
        // Relaxed or most_relaxed - combine fuzzy text and phonetic matching in bool.should
        must.push({
          bool: {
            should: [
              {
                multi_match: {
                  query: full_name,
                  type: 'most_fields',
                  fields: [
                    'full_name^3',
                    'full_name.ngram^2',
                    'given_name^2',
                    'family_name^2',
                  ],
                  fuzziness: 'AUTO',
                },
              },
              {
                multi_match: {
                  query: full_name,
                  type: 'best_fields',
                  fields: [
                    'full_name.phonetic^6',
                    'given_name.phonetic^3',
                    'family_name.phonetic^3',
                  ],
                  operator: 'or',
                },
              },
              ...(searchMode === 'most_relaxed'
                ? [
                    {
                      wildcard: {
                        full_name: `*${full_name.toLowerCase()}*`,
                      },
                    },
                  ]
                : []),
            ],
            minimum_should_match: 1,
          },
        })
      }
*/
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

