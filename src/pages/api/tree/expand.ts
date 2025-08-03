// src/pages/api/tree/expand.ts
import type { NextApiRequest, NextApiResponse } from 'next';
import { expandNode } from '@/lib/tree';
import type { Node, Link } from '@/types/familyTree';

type ExpandRequestBody = {
  nodeId: string;
  nodes?: Node[];
  links?: Link[];
};

type ExpandSuccessResponse = {
  deltaNodes: Node[];
  deltaLinks: Link[];
};

type ExpandErrorResponse = {
  error: string;
};

export default async function handler(
  req: NextApiRequest,
  res: NextApiResponse<ExpandSuccessResponse | ExpandErrorResponse>
) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'POST only' });
  }

  const { nodeId, nodes = [], links = [] } = req.body as ExpandRequestBody;

  if (!nodeId) {
    return res.status(400).json({ error: 'Missing nodeId in request body' });
  }

  try {
    const result = await expandNode(nodeId, nodes, links, true);

    // Narrow type safely for delta return
    if ('deltaNodes' in result) {
      return res.status(200).json(result);
    } else {
      return res.status(500).json({ error: 'Unexpected return structure from expandNode' });
    }
  } catch (error) {
    console.error('❌ Error in expand API:', error);
    return res.status(500).json({ error: 'Failed to expand node' });
  }
}
