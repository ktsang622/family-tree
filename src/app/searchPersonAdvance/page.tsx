'use client'

import { useState } from 'react'
import { API_ROUTES } from '@/lib/constants'

export default function SearchPersonPage() {
  const [query, setQuery] = useState({
    full_name: '',
    gender: '',
    dob: '',
    age: '',
    identifier: '',
    father_name: '',
    mother_name: '',
    spouse_name: '',
    child_name: '',
  })
  const [results, setResults] = useState<any[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [searched, setSearched] = useState(false)
  const [tab, setTab] = useState<'basic' | 'advanced'>('basic')

  const handleSearch = async () => {
    setLoading(true)
    setError(null)
    setResults([])
    setSearched(true)

    try {
      const res = await fetch(
        tab === 'advanced' ? API_ROUTES.SEARCH_PERSON_ADVANCE : API_ROUTES.SEARCH_PERSON,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(query),
        }
      )

      if (!res.ok) {
        const errText = await res.text()
        throw new Error(`Error ${res.status}: ${errText}`)
      }

      const data = await res.json()
      setResults(data.hits || [])
    } catch (err: any) {
      setError(err.message || 'Unknown error occurred')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="p-6 max-w-4xl mx-auto">
      <h1 className="text-2xl font-bold mb-4">Search Person</h1>

      {/* Tabs */}
      <div className="flex space-x-4 mb-4">
        <button
          onClick={() => setTab('basic')}
          className={`px-4 py-2 rounded ${tab === 'basic' ? 'bg-blue-600 text-white' : 'bg-gray-100'}`}
        >
          Basic
        </button>
        <button
          onClick={() => setTab('advanced')}
          className={`px-4 py-2 rounded ${tab === 'advanced' ? 'bg-blue-600 text-white' : 'bg-gray-100'}`}
        >
          Advanced
        </button>
      </div>

      <div className="space-y-3">
        <input type="text" placeholder="Full name" value={query.full_name} onChange={e => setQuery({ ...query, full_name: e.target.value })} className="w-full border p-2 rounded" />
        <select value={query.gender} onChange={e => setQuery({ ...query, gender: e.target.value })} className="w-full border p-2 rounded">
          <option value="">Select Gender</option>
          <option value="male">Male</option>
          <option value="female">Female</option>
        </select>
        <input type="date" value={query.dob} onChange={e => setQuery({ ...query, dob: e.target.value })} className="w-full border p-2 rounded" />
        <input type="number" placeholder="Age (approx)" value={query.age} onChange={e => setQuery({ ...query, age: e.target.value })} className="w-full border p-2 rounded" />
        <input type="text" placeholder="Identifier" value={query.identifier} onChange={e => setQuery({ ...query, identifier: e.target.value })} className="w-full border p-2 rounded" />

        {tab === 'advanced' && (
          <>
            <input type="text" placeholder="Father's Name" value={query.father_name} onChange={e => setQuery({ ...query, father_name: e.target.value })} className="w-full border p-2 rounded" />
            <input type="text" placeholder="Mother's Name" value={query.mother_name} onChange={e => setQuery({ ...query, mother_name: e.target.value })} className="w-full border p-2 rounded" />
            <input type="text" placeholder="Spouse's Name" value={query.spouse_name} onChange={e => setQuery({ ...query, spouse_name: e.target.value })} className="w-full border p-2 rounded" />
            <input type="text" placeholder="Child's Name" value={query.child_name} onChange={e => setQuery({ ...query, child_name: e.target.value })} className="w-full border p-2 rounded" />
          </>
        )}

        <button onClick={handleSearch} disabled={loading} className="bg-blue-600 text-white px-4 py-2 rounded">
          {loading ? 'Searching...' : 'Search'}
        </button>

        {error && (
          <div className="bg-red-100 text-red-700 p-3 rounded mt-2 border border-red-300">{error}</div>
        )}
      </div>

      {!loading && searched && results.length === 0 && !error && (
        <div className="mt-6 text-gray-500 text-center">No results found.</div>
      )}

      {results.length > 0 && (
        <div className="mt-6">
          <h2 className="text-xl font-semibold mb-2">Results:</h2>
          <table className="w-full border text-sm">
            <thead className="bg-gray-100">
              <tr>
                <th className="border px-2 py-1 text-left">Full Name</th>
                <th className="border px-2 py-1 text-left">Gender</th>
                <th className="border px-2 py-1 text-left">DOB</th>
                <th className="border px-2 py-1 text-left">Score</th>
                <th className="border px-2 py-1 text-left">UUID</th>
              </tr>
            </thead>
            <tbody>
              {results.map((person: any) => (
                <tr key={person.id} onClick={() => setSelectedId(person.id)} className="cursor-pointer hover:bg-blue-100">
                  <td className="border px-2 py-1">{person.full_name}</td>
                  <td className="border px-2 py-1 capitalize">{person.gender}</td>
                  <td className="border px-2 py-1">{person.dob ? new Date(person.dob).toLocaleDateString() : '—'}</td>
                  <td className="border px-2 py-1">{(person._score ?? 0).toFixed(3)}</td>
                  <td className="border px-2 py-1 font-mono text-xs">{person.id}</td>
                </tr>
              ))}
            </tbody>
          </table>

          {selectedId && (
            <div className="mt-4 p-3 border rounded bg-green-50">
              <strong>Selected UUID:</strong> <span className="font-mono">{selectedId}</span>
            </div>
          )}
        </div>
      )}
    </div>
  )
}