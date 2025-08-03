import { NextApiRequest, NextApiResponse } from 'next';

export default function handler(req: NextApiRequest, res: NextApiResponse) {
  res.status(200).json({ 
    message: 'API working',
    env: {
      PGUSER: process.env.PGUSER,
      PGHOST: process.env.PGHOST,
      PGDATABASE: process.env.PGDATABASE,
      PGPORT: process.env.PGPORT
    }
  });
}