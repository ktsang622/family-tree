// src/middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

function isTokenExpired(token: string): boolean {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString());
    const now = Math.floor(Date.now() / 1000);
    return payload.exp < now;
  } catch {
    return true;
  }
}

export function middleware(request: NextRequest) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token');

  if (token && !isTokenExpired(token)) {
    const cleanUrl = new URL(url.origin + url.pathname); // remove token param
    const response = NextResponse.redirect(cleanUrl);

    response.cookies.set('opencrvs_token', token, {
      httpOnly: true,
      secure: true,
      path: '/',
      maxAge: 60 * 60, // 1 hour
    });

    return response;
  }

  return NextResponse.next();
}

export const config = {
  matcher: ['/testSSO'],
};

