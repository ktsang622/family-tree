'use client';

import React, { useEffect, useState } from 'react';
import axios from 'axios';
import type { Node, Link, FamilyTreeData } from '@/types/familyTree';
import { Tooltip } from 'react-tooltip';
import 'react-tooltip/dist/react-tooltip.css';

const boxWidth = 180;
const boxHeight = 70;
const levelSpacing = 240;
const rowSpacing = 100;

type Props = {
  personId: string;
};

export default function FamilyTree({ personId }: Props) {
  const [treeData, setTreeData] = useState<FamilyTreeData>({ nodes: [], links: [], expanded: '' });
  const [error, setError] = useState<string | null>(null);
  const [clickedNode, setClickedNode] = useState<string | null>(null);
  const [addedNodeIds, setAddedNodeIds] = useState<Set<string>>(new Set());

  useEffect(() => {
    axios
      .get(`/api/tree/init?person_id=${personId}`)
      .then((res) => setTreeData(res.data))
      .catch((err) => {
        console.error('❌ Init failed', err);
        setError('Could not load tree');
      });
  }, [personId]);

  const levelMap: Record<number, Node[]> = {};
  treeData.nodes.forEach((node) => {
    const level = typeof node.level === 'number' ? node.level : 0;
    if (!levelMap[level]) levelMap[level] = [];
    levelMap[level].push(node);
  });

  const sortedLevels = Object.keys(levelMap)
    .map(Number)
    .sort((a, b) => a - b);

  const positions: Record<string, { x: number; y: number }> = {};

  const nodeBoxes = sortedLevels.flatMap((level, colIndex) =>
    levelMap[level].map((person, rowIndex) => {
      const x = colIndex * levelSpacing;
      const y = rowIndex * rowSpacing;
      positions[person.id] = { x: x + boxWidth / 2, y: y + boxHeight / 2 };

      const isClicked = person.id === clickedNode;
      const isNewlyAdded = addedNodeIds.has(person.id);
      const isRoot = person.id === personId;

      let backgroundColor = '#fdfdfd';
      if (isClicked && isNewlyAdded) {
        backgroundColor = '#ffccbc';
      } else if (isClicked) {
        backgroundColor = '#bbdefb';
      } else if (isNewlyAdded) {
        backgroundColor = '#fff9c4';
      }

      const borderColor = isRoot ? '#4caf50' : '#444';
      const formatDate = (dateStr?: string) => {
        if (!dateStr) return '—';
        const date = new Date(dateStr);
        return isNaN(date.getTime()) ? '—' : date.toISOString().split('T')[0]; // or date.toLocaleDateString()
      };

      return (
        <React.Fragment key={person.id}>
          <div
            data-tooltip-id={`tooltip-${person.id}`}
            data-tooltip-html={`
              <strong>DOB:</strong> ${formatDate(person.dob)}<br />
              <strong>Death:</strong> ${formatDate(person.death) || 'N/A'}<br />
              <strong>${person.id_type_1 || "ID 1"}:</strong> ${person.id_1 || '—'}<br />
              <strong>${person.id_type_2 || "ID 2"}:</strong> ${person.id_2 || '—'}
            `}
            style={{
              position: 'absolute',
              top: y,
              left: x,
              width: boxWidth,
              height: boxHeight,
              border: `2px solid ${borderColor}`,
              borderRadius: 8,
              padding: 8,
              background: backgroundColor,
              fontFamily: 'sans-serif',
              fontSize: 12,
              boxShadow: '2px 2px 4px rgba(0,0,0,0.1)',
              zIndex: 2,
              cursor: 'pointer',
            }}
            onClick={() => {
              setClickedNode(person.id);
              handleExpand(person.id);
            }}
          >
            <strong>{person.full_name}</strong>
            <br />
            {person.id_type_1 || ''}: {person.id_1 || ''}
          </div>

          <Tooltip
            id={`tooltip-${person.id}`}
            place="top"
            offset={10}
            positionStrategy="fixed"
            style={{
              zIndex: 9999,
              pointerEvents: 'auto',
              borderRadius: '6px',
              padding: '6px 10px',
              backgroundColor: '#333',
              color: '#fff',
              maxWidth: '250px',
              fontSize: '12px',
            }}
          />
        </React.Fragment>

      );
    })
  );

  const lines = treeData.links.map((link, i) => {
    const from = positions[link.from];
    const to = positions[link.to];
    if (!from || !to) return null;

    return (
      <line
        key={i}
        x1={from.x}
        y1={from.y}
        x2={to.x}
        y2={to.y}
        stroke="gray"
        strokeDasharray={link.end_date ? '4 2' : '0'}
        strokeWidth={2}
      />
    );
  });

  const handleExpand = async (nodeId: string) => {
    try {
      const res = await axios.post<{
        deltaNodes: Node[];
        deltaLinks: Link[];
      }>('/api/tree/expand', {
        nodeId,
        nodes: treeData.nodes,
        links: treeData.links,
      });

      const { deltaNodes, deltaLinks } = res.data;

      const nodeMap = new Map<string, Node>();
      [...treeData.nodes, ...deltaNodes].forEach((n) => nodeMap.set(n.id, n));
      const mergedNodes = Array.from(nodeMap.values());

      const linkKey = (l: Link) => `${l.from}-${l.to}-${l.relationship}`;
      const linkMap = new Map<string, Link>();
      [...treeData.links, ...deltaLinks].forEach((l) => linkMap.set(linkKey(l), l));
      const mergedLinks = Array.from(linkMap.values());

      const deltaIds = new Set<string>(deltaNodes.map((n) => n.id));
      setAddedNodeIds(deltaIds);

      setTreeData({
        nodes: mergedNodes,
        links: mergedLinks,
        expanded: nodeId,
      });
    } catch (err) {
      console.error('❌ Expansion failed', err);
      setError('Could not expand node');
    }
  };

  return (
    <div style={{ position: 'relative', width: '3000px', height: '2000px', overflow: 'auto' }}>
      {error && <p style={{ color: 'red' }}>{error}</p>}

      {sortedLevels.map((level, colIndex) => {
        const x = colIndex * levelSpacing;
        return (
          <div
            key={`level-${level}`}
            style={{
              position: 'absolute',
              top: -30,
              left: x,
              width: boxWidth,
              textAlign: 'center',
              fontSize: 14,
              fontWeight: 'bold',
              fontFamily: 'sans-serif',
              color: '#333',
            }}
          >
            Level {level}
          </div>
        );
      })}

      {nodeBoxes}

      <svg
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          width: '3000px',
          height: '2000px',
          pointerEvents: 'none',
          zIndex: 1,
        }}
      >
        {lines}
      </svg>
    </div>
  );
}
