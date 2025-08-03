export type Node = {
  id: string;
  full_name: string;
  dob?: string;
  death?: string;
  level?: number;
  id_type_1?: string;
  id_1?: string;
  id_type_2?: string;
  id_2?: string;
  id_type_3?: string;
  id_3?: string;
};

export type Link = {
  from: string;
  to: string;
  relationship: string;
  start_date: string | null;
  end_date: string | null;
};

export type FamilyTreeData = {
  nodes: Node[];
  links: Link[];
  expanded: string;
};
