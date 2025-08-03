import { query } from '@/lib/db';
import type { Node, Link } from '@/types/familyTree';

export async function getPersonById(id: string): Promise<Node[]> {
  const result = await query(
    `WITH filtered_ids AS (
        SELECT p.id, jsonb_array_elements(p.identifiers)::jsonb AS id_obj
        FROM public.person p
        WHERE p.id = $1
      ), deduplicated_ids AS (
        SELECT DISTINCT id, id_obj ->> 'type' AS id_type, id_obj ->> 'value' AS id_value
        FROM filtered_ids
      ), indexed_ids AS (
        SELECT id, id_type, id_value,
          ROW_NUMBER() OVER (
            PARTITION BY id
            ORDER BY CASE WHEN id_type = 'crvs' THEN 2 ELSE 1 END, id_type
          ) AS rn
        FROM deduplicated_ids
      )
      SELECT p.id, p.full_name, p.dob, p.death_date AS death,
             AGE(COALESCE(p.death_date, NOW()), p.dob) AS age,
             MAX(CASE WHEN i.rn = 1 THEN i.id_type END) AS id_type_1,
             MAX(CASE WHEN i.rn = 1 THEN i.id_value END) AS id_1,
             MAX(CASE WHEN i.rn = 2 THEN i.id_type END) AS id_type_2,
             MAX(CASE WHEN i.rn = 2 THEN i.id_value END) AS id_2,
             MAX(CASE WHEN i.rn = 3 THEN i.id_type END) AS id_type_3,
             MAX(CASE WHEN i.rn = 3 THEN i.id_value END) AS id_3
      FROM public.person p
      LEFT JOIN indexed_ids i ON p.id = i.id
      WHERE p.id = $1
      GROUP BY p.id, p.full_name, p.dob, p.death_date`,
    [id]
  );
  return result || [];
}

export async function getParentsFromFamilyLink(personId: string): Promise<any[]> {
  return (
    (await query(
      `SELECT related_person_id AS parent_person_id, relationship_type, start_date, end_date
       FROM family_link
       WHERE person_id = $1 AND relationship_type IN ('mother', 'father')`,
      [personId]
    )) || []
  );
}

export async function getChildrenFromFamilyLink(personId: string): Promise<any[]> {
  return (
    (await query(
      `SELECT related_person_id AS child_id, relationship_type, start_date, end_date
       FROM family_link
       WHERE person_id = $1 AND relationship_type = 'child'`,
      [personId]
    )) || []
  );
}

export async function getSpousesFromFamilyLink(personId: string): Promise<any[]> {
  return (
    (await query(
      `SELECT related_person_id AS spouse_id, relationship_type, start_date, end_date
       FROM family_link
       WHERE person_id = $1 AND relationship_type = 'spouse'`,
      [personId]
    )) || []
  );
}

export async function getFamilyLevels(
  rootId: string,
  depthUp = 1,
  depthDown = 1,
  existingTree: Node[] = [],
  baseLevel = 0,
  existingLinks: Link[] = []
): Promise<{ nodes: Node[]; links: Link[] }> {
  const visited = new Set(existingTree.map((p) => p.id));
  const existingLinkKeys = new Set(
    existingLinks.map((l) => `${l.from}-${l.to}-${l.relationship}`)
  );

  const newNodes: Node[] = [];
  const links: Link[] = [];

  const linkKey = (from: string, to: string, rel: string) => `${from}-${to}-${rel}`;

  const getPerson = async (id: string, level: number) => {
    if (visited.has(id)) return;
    visited.add(id);
    const person = await getPersonById(id);
    if (person.length > 0) {
      newNodes.push({ level, ...person[0] });
    }
  };

  const getAncestors = async (id: string, level: number) => {
    if (level < baseLevel - depthUp) return;

    const parents = await getParentsFromFamilyLink(id);
    for (const p of parents) {
      const parentId = p.parent_person_id;
      const key = linkKey(parentId, id, p.relationship_type);

      if (!existingLinkKeys.has(key)) {
        links.push({
          from: parentId,
          to: id,
          relationship: p.relationship_type,
          start_date: p.start_date,
          end_date: p.end_date,
        });
        existingLinkKeys.add(key);
      }

      if (!visited.has(parentId)) {
        await getPerson(parentId, level);
        await getAncestors(parentId, level - 1);
      }
    }
  };

  const getDescendants = async (id: string, level: number) => {
    if (level > baseLevel + depthDown) return;

    const children = await getChildrenFromFamilyLink(id);
    for (const c of children) {
      const childId = c.child_id;
      const key = linkKey(id, childId, c.relationship_type);

      if (!existingLinkKeys.has(key)) {
        links.push({
          from: id,
          to: childId,
          relationship: c.relationship_type,
          start_date: c.start_date,
          end_date: c.end_date,
        });
        existingLinkKeys.add(key);
      }

      if (!visited.has(childId)) {
        await getPerson(childId, level);
        await getDescendants(childId, level + 1);
        await getAncestors(childId, level - 1); // ✅ Add this to link child to both parents
      }
    }
  };


  const getSpouses = async (id: string, level: number) => {
    const spouses = await getSpousesFromFamilyLink(id);
    for (const s of spouses) {
      const spouseId = s.spouse_id;
      const key = linkKey(id, spouseId, s.relationship_type);

      if (!existingLinkKeys.has(key)) {
        links.push({
          from: id,
          to: spouseId,
          relationship: s.relationship_type,
          start_date: s.start_date,
          end_date: s.end_date,
        });
        existingLinkKeys.add(key);
      }

      if (!visited.has(spouseId)) {
        await getPerson(spouseId, level);
        // Not recursing into spouses
      }
    }
  };

  // Seed tree
  await getPerson(rootId, baseLevel);
  await getSpouses(rootId, baseLevel);
  await getAncestors(rootId, baseLevel - 1);
  await getDescendants(rootId, baseLevel + 1);

  return { nodes: newNodes, links };
}

export async function expandNode(
  nodeId: string,
  existingTree: Node[] = [],
  existingLinks: Link[] = [],
  returnDelta = true
): Promise<
  | { deltaNodes: Node[]; deltaLinks: Link[] }
  | { fullTree: Node[]; fullLinks: Link[] }
> {
  const node = existingTree.find((n) => n.id === nodeId);
  const baseLevel = node?.level ?? 0;

  const { nodes: newNodes, links: newLinks } = await getFamilyLevels(
    nodeId,
    1,
    1,
    existingTree,
    baseLevel,
    existingLinks
  );

  const updatedTree = [...existingTree, ...newNodes];
  const updatedLinks = [...existingLinks, ...newLinks];

  return returnDelta
    ? { deltaNodes: newNodes, deltaLinks: newLinks }
    : { fullTree: updatedTree, fullLinks: updatedLinks };
}
