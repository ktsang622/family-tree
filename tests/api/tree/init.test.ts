import type { NextApiRequest, NextApiResponse } from 'next';
import { getFamilyLevels } from '@/lib/tree';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  try {
    const rootId = '46d53bb1-69cd-4b90-ba39-2f13d8eed0ca';
    const { nodes, links } = await getFamilyLevels(rootId, 1, 1);
    res.status(200).json({ nodes, links });
  } catch (error) {
    console.error("❌ Init tree test failed:", error);
    res.status(500).json({ error: "Init tree test failed", details: (error as Error).message });
  }
}
