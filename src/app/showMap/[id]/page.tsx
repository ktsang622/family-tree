import { use } from 'react';
import FamilyTree from '@/components/FamilyTree';

export default function ShowMapPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params); // ✅ unwrap the async params
  return (
    <div style={{ padding: 16 }}>
      <h2>Family Tree Viewer</h2>
      <FamilyTree personId={id} />
    </div>
  );
}
