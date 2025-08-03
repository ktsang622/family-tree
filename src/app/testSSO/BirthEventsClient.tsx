// src/app/testSSO/BirthEventsClient.tsx
'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';

export default function BirthEventsClient({ token }: { token: string }) {
  const [events, setEvents] = useState<any[]>([]);
  const router = useRouter();
  useEffect(() => {
    if (!token) return;

    fetch('https://gateway.opencrvs.ktsang.com/graphql', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        query: `query searchEvents($event: EventType!, $count: Int) {
          searchEvents(advancedSearchParameters: { event: $event }, count: $count) {
            results { id registration { trackingId } }
            totalItems
          }
        }`,
        variables: { event: 'birth', count: 5 },
      }),
    })
      .then(async (res) => {
        if (res.status === 401) {
          // Token invalid → logout + redirect
          document.cookie = 'opencrvs_token=; Max-Age=0; path=/';
          router.replace('https://login.opencrvs.ktsang.com/?redirectTo=https://fmap.opencrvs.ktsang.com/testSSO');
          return;
        }

        const data = await res.json();
        setEvents(data?.data?.searchEvents?.results || []);
      });
  }, [token]); 

  return (
    <div>
      <h1>🔐 Birth Events (Client)</h1>
      <ul>
        {events.map((e) => (
          <li key={e.id}>{e.registration?.trackingId}</li>
        ))}
      </ul>
    </div>
  );
}
