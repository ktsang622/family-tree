// src/app/testSSO/page.tsx
import { cookies } from 'next/headers'; // ✅ CORRECT import
import { redirect } from 'next/navigation';

import { Buffer } from 'buffer';
import BirthEventsClient from './BirthEventsClient';

function getTokenPayload(token: string) {
  try {
    const base64Payload = token.split('.')[1];
    const json = Buffer.from(base64Payload, 'base64').toString();
    return JSON.parse(json);
  } catch {
    return null;
  }
}

export default async function TestSSOPage() {
  const token = (await cookies()).get('opencrvs_token')?.value;

  if (!token) {
    return redirect('https://login.opencrvs.ktsang.com/?redirectTo=https://fmap.opencrvs.ktsang.com/testSSO');
  }

  const payload = getTokenPayload(token);
  if (!payload) {
    return redirect('https://login.opencrvs.ktsang.com/?redirectTo=https://fmap.opencrvs.ktsang.com/testSSO');
  }

  const scopes: string[] = payload.scope || [];
  const canRegister = scopes.some(scope => scope.startsWith('record.register'));

  if (!canRegister) {
    return <div>🚫 You do not have permission to register records.</div>;
  }

  return <BirthEventsClient token={token} />;
}
