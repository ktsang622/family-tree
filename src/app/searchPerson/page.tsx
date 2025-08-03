// src/app/searchPerson/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { API_ROUTES } from '@/lib/constants'

export default function SearchPersonPage() {
  const [query, setQuery] = useState({
    full_name: '',
    gender: '',
    dob: '',
    age: '',
    identifier: '',
    searchMode: 'relaxer',
    page: 1,
    pageSize: 10,
  })

  const [results, setResults] = useState<any[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [searched, setSearched] = useState(false)
  const [totalPages, setTotalPages] = useState(1)
  const [totalResults, setTotalResults] = useState(0)

  useEffect(() => {
    if (typeof window !== 'undefined') {
      const savedPageSize = parseInt(localStorage.getItem('pageSize') || '10')
      setQuery(prev => ({ ...prev, pageSize: savedPageSize }))
    }
  }, [])

  useEffect(() => {
    if (searched) handleSearch(query)
  }, [query.page, query.pageSize])

  const handleSearch = async (q = query) => {
    setLoading(true)
    setError(null)
    setResults([])

    try {
      const res = await fetch(API_ROUTES.SEARCH_PERSON, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(q),
      })

      if (!res.ok) {
        const errText = await res.text()
        throw new Error(`Error ${res.status}: ${errText}`)
      }

      const data = await res.json()
      setResults(data.hits || [])
      setTotalResults(data.total || 0)
      setTotalPages(Math.ceil((data.total || 0) / q.pageSize))
    } catch (err: any) {
      setError(err.message || 'Unknown error occurred')
    } finally {
      setLoading(false)
    }
  }

  const onSearchClick = () => {
    const updated = { ...query, page: 1 }
    setQuery(updated)
    setSearched(true)
    handleSearch(updated)
  }

  const changePageSize = (size: number) => {
    localStorage.setItem('pageSize', size.toString())
    const updated = { ...query, pageSize: size, page: 1 }
    setQuery(updated)
    handleSearch(updated)
  }

  const goToPage = (pageNum: number) => {
    if (pageNum >= 1 && pageNum <= totalPages) {
      setQuery(prev => ({ ...prev, page: pageNum }))
    }
  }

  return (
    <div className="p-6 max-w-3xl mx-auto">
      <h1 className="text-2xl font-bold mb-4">Search Person</h1>

      <div className="space-y-3">
        <input
          type="text"
          placeholder="Full name"
          value={query.full_name}
          onChange={e => setQuery({ ...query, full_name: e.target.value })}
          className="w-full border p-2 rounded"
        />

        <select
          value={query.gender}
          onChange={e => setQuery({ ...query, gender: e.target.value })}
          className="w-full border p-2 rounded"
        >
          <option value="">Select Gender</option>
          <option value="male">Male</option>
          <option value="female">Female</option>
        </select>

        <input
          type="date"
          value={query.dob}
          onChange={e => setQuery({ ...query, dob: e.target.value })}
          className="w-full border p-2 rounded"
        />

        <input
          type="number"
          placeholder="Age (approx)"
          value={query.age}
          onChange={e => setQuery({ ...query, age: e.target.value })}
          className="w-full border p-2 rounded"
        />

        <input
          type="text"
          placeholder="Identifier"
          value={query.identifier}
          onChange={e => setQuery({ ...query, identifier: e.target.value })}
          className="w-full border p-2 rounded"
        />

        <label className="block text-sm font-medium text-gray-700 mb-1">Search Mode</label>
        <div className="flex flex-col space-y-1 text-sm">
          {['strict', 'relaxer', 'most_relaxed'].map(mode => (
            <label key={mode} className="inline-flex items-center">
              <input
                type="radio"
                name="searchMode"
                value={mode}
                checked={query.searchMode === mode}
                onChange={() => setQuery({ ...query, searchMode: mode })}
              />
              <span className="ml-2 capitalize">{mode.replace('_', ' ')}</span>
            </label>
          ))}
        </div>

        <select
          value={query.pageSize}
          onChange={e => changePageSize(parseInt(e.target.value))}
          className="w-full border p-2 rounded"
        >
          {[5, 10, 20, 50].map(size => (
            <option key={size} value={size}>{size} per page</option>
          ))}
        </select>

        <button
          onClick={onSearchClick}
          disabled={loading}
          className="bg-blue-600 text-white px-4 py-2 rounded"
        >
          {loading ? 'Searching...' : 'Search'}
        </button>

        {error && <div className="bg-red-100 text-red-700 p-3 rounded mt-2 border border-red-300">{error}</div>}
      </div>

      {!loading && searched && results.length === 0 && !error && (
        <div className="mt-6 text-gray-500 text-center">No results found.</div>
      )}

      {results.length > 0 && (
        <div className="mt-6">
          <h2 className="text-xl font-semibold mb-2">Results ({totalResults}):</h2>
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
                <tr
                  key={person.id}
                  onClick={() => setSelectedId(person.id)}
                  className="cursor-pointer hover:bg-blue-100"
                >
                  <td className="border px-2 py-1">{person.full_name}</td>
                  <td className="border px-2 py-1 capitalize">{person.gender}</td>
                  <td className="border px-2 py-1">{person.dob ? new Date(person.dob).toLocaleDateString() : '—'}</td>
                  <td className="border px-2 py-1">{(person._score ?? 0).toFixed(3)}</td>
                  <td className="border px-2 py-1 font-mono text-xs">{person.id}</td>
                </tr>
              ))}
            </tbody>
          </table>

          {totalPages > 1 && (
            <div className="flex justify-between items-center mt-4 text-sm">
              <div>
                Page {query.page} of {totalPages}
              </div>
              <div className="space-x-2">
                <button onClick={() => goToPage(query.page - 1)} disabled={query.page <= 1} className="px-2 py-1 border rounded">Prev</button>
                <input
                  type="number"
                  value={query.page}
                  min={1}
                  max={totalPages}
                  onChange={e => goToPage(parseInt(e.target.value))}
                  className="w-16 border p-1 rounded text-center"
                />
                <button onClick={() => goToPage(query.page + 1)} disabled={query.page >= totalPages} className="px-2 py-1 border rounded">Next</button>
              </div>
            </div>
          )}

          {selectedId && (
            <div className="mt-4 p-3 border rounded bg-green-50">
              <strong>Selected UUID:</strong>{' '}
              <span className="font-mono">{selectedId}</span>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

