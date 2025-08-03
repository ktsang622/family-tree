import type { NextApiRequest, NextApiResponse } from 'next';
import { getFamilyLevels, expandNode } from '@/lib/tree';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  const nodeId = '46d53bb1-69cd-4b90-ba39-2f13d8eed0ca';
  const expandId1 = 'd57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c';
  const expandId2 = '3df5bc57-427c-446c-8201-f9695bcdd6d5';

  try {
    const { nodes, links } = await getFamilyLevels(nodeId, 1, 1);

    const { deltaNodes, deltaLinks } = await expandNode(expandId1, nodes, links, true);

    const { fullTree: updatedTree, fullLinks: updatedLinks } = await expandNode(
      expandId2,
      [...nodes, ...deltaNodes],
      [...links, ...deltaLinks],
      false
    );

    return res.status(200).json({
      step1: { nodes, links },
      step2: { deltaNodes, deltaLinks },
      step3: { updatedTree, updatedLinks }
    });
  } catch (err) {
    console.error("❌ Expand Tree Test Error:", err);
    return res.status(500).json({ error: 'Expand tree test failed' });
  }
}