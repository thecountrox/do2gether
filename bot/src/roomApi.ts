export interface Member {
  user_id: string;
  name: string;
}

export interface Room {
  room_id: string;
  host_id: string;
  host_name: string | null;
  members: Member[];
  rev: number;
  playback: { item_ref: string; position_ms: number; paused: boolean } | null;
  locked: boolean;
  controls: 'host' | 'all';
}

export interface RoomStats {
  room_id: string;
  rev: number;
  members: number;
  p50_drift_ms: number | null;
  p95_drift_ms: number | null;
  corrections: number;
}

export interface Stats {
  rooms: RoomStats[];
}

export class RoomApiError extends Error {
  constructor(public readonly status: number, public readonly code: string) {
    super(`Room server: ${code} (HTTP ${status})`);
    this.name = 'RoomApiError';
  }
}

export function roomUrl(base: string, ...parts: string[]): string {
  const url = new URL(base);
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${parts.map(encodeURIComponent).join('/')}`;
  return url.toString();
}

export function createRoomApi(base: string, botToken: string, fetcher: typeof fetch = fetch) {
  async function request<T>(method: string, parts: string[], body?: object): Promise<T> {
    const response = await fetcher(roomUrl(base, ...parts), {
      method,
      headers: {
        Authorization: `Bearer ${botToken}`,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    if (!response.ok) {
      const payload: unknown = await response.json().catch(() => null);
      const code = payload && typeof payload === 'object' && 'error' in payload
        && typeof payload.error === 'string' ? payload.error : `http_${response.status}`;
      throw new RoomApiError(response.status, code);
    }
    return response.status === 204 ? undefined as T : await response.json() as T;
  }
  return {
    create: (body: { host_id: string; host_name: string; guild_id: string; voice_channel_id: string }) =>
      request<{ room_id: string; join_token: string; host_id: string }>('POST', ['rooms'], body),
    token: (id: string, body: { user_id: string; user_name: string }) =>
      request<{ room_id: string; join_token: string; expires_in_ms: number }>('POST', ['rooms', id, 'tokens'], body),
    get: (id: string) => request<Room>('GET', ['rooms', id]),
    patch: (id: string, body: { locked?: boolean; controls?: 'host' | 'all' }) =>
      request<Room>('PATCH', ['rooms', id], body),
    delete: (id: string) => request<void>('DELETE', ['rooms', id]),
    stats: () => request<Stats>('GET', ['stats']),
  };
}
