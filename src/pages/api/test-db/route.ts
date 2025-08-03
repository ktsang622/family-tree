// src/app/api/test-db/route.ts
import { query } from '@/lib/db';
import { NextResponse } from 'next/server';

export async function GET() {
  try {
    const rows = await query('SELECT 1 AS ok');
    return NextResponse.json({ success: true, rows });
  } catch (err: any) {
    console.error('❌ Test DB Error:', err);
    return NextResponse.json({ error: err.message }, { status: 500 });
  }
}
