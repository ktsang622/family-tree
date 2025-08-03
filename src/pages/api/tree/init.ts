// src/pages/api/tree/init.ts
import type { NextApiRequest, NextApiResponse } from 'next';
import { getFamilyLevels } from '@/lib/tree';
import type { Node, Link } from '@/types/familyTree';

type InitSuccessResponse = {
  nodes: Node[];
  links: Link[];
  expanded: string;
};

type InitErrorResponse = {
  error: string;
};

export default async function handler(
  req: NextApiRequest,
  res: NextApiResponse<InitSuccessResponse | InitErrorResponse>
) {
  const { person_id } = req.query;

  if (!person_id || typeof person_id !== 'string') {
    return res.status(400).json({ error: 'Missing person_id query param' });
  }

  console.log('📥 API route /api/tree/init called with:', person_id);

  try {
    const { nodes, links } = await getFamilyLevels(person_id, 1, 1, [], 0);
    return res.status(200).json({ nodes, links, expanded: person_id });
  } catch (error) {
    console.error('❌ Error in init API:', error);
    return res.status(500).json({ error: 'Failed to fetch tree' });
  }
}
