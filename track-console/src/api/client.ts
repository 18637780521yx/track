import dayjs, { Dayjs } from 'dayjs';

const API_BASE = '';

export type DateRange = [Dayjs, Dayjs];

export function defaultRange(days = 7): DateRange {
  const end = dayjs().endOf('day');
  const start = end.subtract(days - 1, 'day').startOf('day');
  return [start, end];
}

function rangeParams(range: DateRange) {
  return {
    from: range[0].toISOString(),
    to: range[1].toISOString(),
  };
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, init);
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export interface OverviewStats {
  dau: number;
  new_users: number;
  installs: number;
  revenue: number;
  paying_users: number;
  active_subscriptions: number;
  total_events: number;
  top_events: { name: string; count: number }[];
  trend: {
    date: string;
    count: number;
    users: number;
    new_users?: number;
    installs?: number;
    revenue?: number;
    active_subscriptions?: number;
  }[];
}

export interface EventRecord {
  event_id: string;
  name: string;
  properties: Record<string, unknown>;
  common_properties?: Record<string, unknown>;
  distinct_id?: string | null;
  anonymous_id: string;
  session_id: string;
  event_time: string;
  received_at: string;
}

export interface FunnelStep {
  name: string;
  users: number;
  conversion: number;
}

export interface RetentionRow {
  cohort_date: string;
  cohort_size: number;
  retention: number[];
}

export interface UserRecord {
  user_id: string;
  distinct_id?: string | null;
  anonymous_id: string;
  first_seen_at: string;
  last_seen_at: string;
  first_open_at?: string | null;
  signup_at?: string | null;
  is_paid: boolean;
  total_revenue: number;
  channel?: string | null;
}

export const api = {
  overview(range: DateRange) {
    const q = new URLSearchParams(rangeParams(range));
    return request<OverviewStats>(`/api/v1/overview?${q}`);
  },
  eventNames(search = '') {
    const q = new URLSearchParams();
    if (search) q.set('q', search);
    const suffix = q.toString() ? `?${q}` : '';
    return request<{ items: { name: string; count: number }[] }>(`/api/v1/events/names${suffix}`);
  },
  eventTrend(range: DateRange, event?: string, unit = 'day') {
    const q = new URLSearchParams({ ...rangeParams(range), unit });
    if (event) q.set('event', event);
    return request<{ items: { bucket: string; count: number; users: number }[] }>(
      `/api/v1/events/trend?${q}`,
    );
  },
  listEvents(range: DateRange, event?: string, limit = 50, offset = 0) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
    });
    if (event) q.set('event', event);
    return request<{ items: EventRecord[]; total: number }>(`/api/v1/events?${q}`);
  },
  funnel(range: DateRange, steps: string[], windowHours = 24) {
    return request<{ steps: FunnelStep[] }>('/api/v1/funnel', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        steps,
        from: range[0].toISOString(),
        to: range[1].toISOString(),
        window_hours: windowHours,
      }),
    });
  },
  retention(range: DateRange, cohortEvent: string, returnEvent: string, days = 7) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      cohort_event: cohortEvent,
      return_event: returnEvent,
      days: String(days),
    });
    return request<{ days: number[]; rows: RetentionRow[] }>(`/api/v1/retention?${q}`);
  },
  listUsers(search = '', limit = 50, offset = 0) {
    const q = new URLSearchParams({ limit: String(limit), offset: String(offset) });
    if (search) q.set('q', search);
    return request<{ items: UserRecord[]; total: number }>(`/api/v1/users?${q}`);
  },
  getUser(userId: string) {
    return request<UserRecord>(`/api/v1/users/${encodeURIComponent(userId)}`);
  },
  listUserEvents(userId: string, range: DateRange, limit = 500, offset = 0) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
    });
    return request<{ items: EventRecord[]; total: number }>(
      `/api/v1/users/${encodeURIComponent(userId)}/events?${q}`,
    );
  },
};
