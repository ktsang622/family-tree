"use client";

import { useState } from "react";

export default function SearchPerson2() {
  const [givenName, setGivenName] = useState("");
  const [familyName, setFamilyName] = useState("");
  const [fullName, setFullName] = useState("");
  const [results, setResults] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [searchMode, setSearchMode] = useState("relaxer");

  const handleSearch = async () => {
    setLoading(true);
    try {
      const res = await fetch("/api/opensearch/search-person2", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          given_name: givenName,
          family_name: familyName,
          full_name: fullName,
          searchMode,
          pageSize: 20,
        }),
      });
      const data = await res.json();
      setResults(data.hits || []);
    } catch (err) {
      console.error("Search failed", err);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="p-6 max-w-3xl mx-auto">
      <h1 className="text-xl font-bold mb-4">Search Person (Split Fields)</h1>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
        <input
          type="text"
          placeholder="Given Name"
          value={givenName}
          onChange={(e) => setGivenName(e.target.value)}
          className="border p-2 rounded"
        />
        <input
          type="text"
          placeholder="Family Name"
          value={familyName}
          onChange={(e) => setFamilyName(e.target.value)}
          className="border p-2 rounded"
        />
        <input
          type="text"
          placeholder="Full Name (optional)"
          value={fullName}
          onChange={(e) => setFullName(e.target.value)}
          className="border p-2 rounded"
        />
      </div>

      <div className="mb-4">
        <label className="mr-2 font-semibold">Search Mode:</label>
        <select
          value={searchMode}
          onChange={(e) => setSearchMode(e.target.value)}
          className="border p-2 rounded"
        >
          <option value="strict">Strict</option>
          <option value="relaxer">Relaxer</option>
          <option value="most_relaxed">Most Relaxed</option>
        </select>
      </div>

      <button
        onClick={handleSearch}
        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
      >
        {loading ? "Searching..." : "Search"}
      </button>

      <div className="mt-6">
        <h2 className="font-bold mb-2">Results:</h2>
        <ul className="space-y-2">
          {results.map((person, idx) => (
            <li key={idx} className="border p-3 rounded shadow">
              <div><strong>Name:</strong> {person.full_name}</div>
              <div><strong>Given:</strong> {person.given_name}</div>
              <div><strong>Family:</strong> {person.family_name}</div>
              <div><strong>DOB:</strong> {person.dob || "N/A"}</div>
              <div><strong>Score:</strong> {person._score?.toFixed(2)}</div>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

