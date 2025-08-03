import { NextApiRequest, NextApiResponse } from 'next';
import { Pool } from 'pg';

const pool = new Pool({
  user: process.env.PGUSER || 'registry_user',
  host: process.env.PGHOST || 'localhost',
  database: process.env.PGDATABASE || 'person_registry',
  password: process.env.PGPASSWORD || 'registry_pass',
  port: parseInt(process.env.PGPORT || '5432'),
});

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  console.log('API called:', req.url);
  console.log('DB config:', {
    user: process.env.PGUSER,
    host: process.env.PGHOST,
    database: process.env.PGDATABASE,
    port: process.env.PGPORT
  });

  if (req.method !== 'GET') {
    return res.status(405).json({ message: 'Method not allowed' });
  }

  const { id: personId } = req.query;
  console.log('Person ID:', personId);

  if (!personId || typeof personId !== 'string') {
    return res.status(400).json({ message: 'Person ID is required' });
  }

  try {
    // Get person details
    const personQuery = `
      SELECT 
        id,
        given_name,
        family_name,
        full_name,
        gender,
        dob,
        place_of_birth,
        identifiers,
        status
      FROM person 
      WHERE id = $1
    `;
    
    const personResult = await pool.query(personQuery, [personId]);
    
    if (personResult.rows.length === 0) {
      return res.status(404).json({ message: 'Person not found' });
    }

    const person = personResult.rows[0];

    // Get events for this person
    const eventsQuery = `
      SELECT 
        e.id as event_id,
        e.event_type,
        e.event_date,
        e.location,
        e.source,
        e.metadata,
        e.status as event_status,
        e.crvs_event_uuid,
        ep.role,
        ep.relationship_details,
        ep.status as participant_status
      FROM event e
      JOIN event_participant ep ON e.id = ep.event_id
      WHERE ep.person_id = $1 
        AND ep.status = 'active'
      ORDER BY e.event_date DESC, e.created_at DESC
    `;

    const eventsResult = await pool.query(eventsQuery, [personId]);

    // Format events for the frontend
    const events = eventsResult.rows.map(row => {
      const metadata = row.metadata || {};
      const trackingId = metadata.trackingId || 'N/A';
      const registrationNumber = metadata.registrationNumber || 'N/A';
      
      return {
        type: formatEventType(row.event_type),
        date: row.event_date || 'Unknown',
        status: formatStatus(row.event_status),
        role: formatRole(row.role),
        registrationId: trackingId,
        declarationId: row.crvs_event_uuid,
        crvsEventUuid: row.crvs_event_uuid,
        eventType: row.event_type,
        location: row.location || 'Unknown',
        source: row.source || 'Unknown'
      };
    });

    // Format person data
    const identifiers = person.identifiers || [];
    const nationalId = identifiers.find((id: any) => id.type === 'NATIONAL_ID')?.value || person.id;
    const birthRegNumber = identifiers.find((id: any) => id.type === 'BIRTH_REGISTRATION_NUMBER')?.value;
    
    const responseData = {
      person: {
        id: person.id,
        givenName: person.given_name,
        familyName: person.family_name,
        fullName: person.full_name,
        nationalId: nationalId,
        birthRegistrationNumber: birthRegNumber,
        phone: 'N/A', // Not stored in current schema
        dateOfBirth: person.dob,
        gender: person.gender,
        placeOfBirth: person.place_of_birth,
        status: person.status,
        identifiers: identifiers
      },
      events: events
    };

    res.status(200).json(responseData);

  } catch (error) {
    console.error('Database error:', error);
    res.status(500).json({ message: 'Internal server error' });
  }
}

function formatEventType(eventType: string): string {
  switch (eventType?.toLowerCase()) {
    case 'birth':
      return 'Birth Registration';
    case 'death':
      return 'Death Registration';
    case 'marriage':
      return 'Marriage Registration';
    default:
      return eventType || 'Unknown Event';
  }
}

function formatStatus(status: string): string {
  switch (status?.toLowerCase()) {
    case 'registered':
      return 'Registered';
    case 'declared':
      return 'Declared';
    case 'issued':
      return 'Issued';
    default:
      return status || 'Unknown';
  }
}

function formatRole(role: string): string {
  switch (role?.toLowerCase()) {
    case 'subject':
      return 'Subject';
    case 'mother':
      return 'Mother';
    case 'father':
      return 'Father';
    case 'groom':
      return 'Groom';
    case 'bride':
      return 'Bride';
    case 'informant':
      return 'Informant';
    default:
      return role || 'Unknown';
  }
}