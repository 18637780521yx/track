import dayjs, { Dayjs } from 'dayjs';

const API_BASE = '';

export type DateRange = [Dayjs, Dayjs];

export function defaultRange(days = 7): DateRange {
  const end = dayjs().endOf('day');
  const start = end.subtract(days - 1, 'day').startOf('day');
  return [start, end];
}

/** RangePicker 重选后结束日默认是 00:00:00，需规范为当天起止，否则当天数据会被后端 `< to` 排除 */
export function normalizeRange(range: DateRange): DateRange {
  return [range[0].startOf('day'), range[1].endOf('day')];
}

function rangeParams(range: DateRange) {
  const [from, to] = normalizeRange(range);
  return {
    from: from.toISOString(),
    to: to.toISOString(),
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

export interface EventFilter {
  source: 'common' | 'properties';
  field: string;
  op: 'eq' | 'neq' | 'contains';
  value: string;
}

function appendFilters(q: URLSearchParams, filters?: EventFilter[]) {
  if (filters && filters.length > 0) {
    q.set('filters', JSON.stringify(filters));
  }
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
  eventTrend(range: DateRange, event?: string, unit = 'day', filters?: EventFilter[]) {
    const q = new URLSearchParams({ ...rangeParams(range), unit });
    if (event) q.set('event', event);
    appendFilters(q, filters);
    return request<{ items: { bucket: string; count: number; users: number }[] }>(
      `/api/v1/events/trend?${q}`,
    );
  },
  listEvents(range: DateRange, event?: string, limit = 50, offset = 0, filters?: EventFilter[]) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
    });
    if (event) q.set('event', event);
    appendFilters(q, filters);
    return request<{ items: EventRecord[]; total: number }>(`/api/v1/events?${q}`);
  },
  propertyValues(field: string, source: 'common' | 'properties' = 'common', event = '') {
    const q = new URLSearchParams({ field, source });
    if (event) q.set('event', event);
    return request<{ items: string[] }>(`/api/v1/events/property-values?${q}`);
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
  deleteUser(userId: string) {
    return request<{ ok: boolean; deleted: Record<string, number> }>(
      `/api/v1/users/${encodeURIComponent(userId)}`,
      { method: 'DELETE' },
    );
  },
  listUserEvents(
    userId: string,
    range: DateRange,
    limit = 50,
    offset = 0,
    opts?: { order?: 'asc' | 'desc'; name?: string },
  ) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
      order: opts?.order ?? 'desc',
    });
    if (opts?.name) q.set('name', opts.name);
    return request<{ items: EventRecord[]; total: number }>(
      `/api/v1/users/${encodeURIComponent(userId)}/events?${q}`,
    );
  },
  listUserLogs(
    userId: string,
    range: DateRange,
    limit = 50,
    offset = 0,
    opts?: { order?: 'asc' | 'desc'; level?: string },
  ) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
      order: opts?.order ?? 'desc',
    });
    if (opts?.level) q.set('level', opts.level);
    return request<{ items: EventRecord[]; total: number; ttl_hours?: number }>(
      `/api/v1/users/${encodeURIComponent(userId)}/logs?${q}`,
    );
  },
  deleteUserLogs(userId: string) {
    return request<{ ok: boolean; deleted: number }>(
      `/api/v1/users/${encodeURIComponent(userId)}/logs`,
      { method: 'DELETE' },
    );
  },
  stabilityOverview(range: DateRange) {
    const q = new URLSearchParams(rangeParams(range));
    return request<StabilityOverview>(`/api/v1/stability/overview?${q}`);
  },
  stabilityIssues(range: DateRange, kind = '', limit = 50, offset = 0) {
    const q = new URLSearchParams({
      ...rangeParams(range),
      limit: String(limit),
      offset: String(offset),
    });
    if (kind) q.set('kind', kind);
    return request<{ items: StabilityIssueSummary[]; total: number }>(
      `/api/v1/stability/issues?${q}`,
    );
  },
  stabilityIssue(fingerprint: string, limit = 50, offset = 0) {
    const q = new URLSearchParams({
      limit: String(limit),
      offset: String(offset),
    });
    return request<StabilityIssueDetail>(
      `/api/v1/stability/issues/${encodeURIComponent(fingerprint)}?${q}`,
    );
  },
};

export interface StabilityOverview {
  crash: number;
  error: number;
  anr: number;
  issue_count: number;
  affected_users: number;
  trend: { date: string; crash: number; error: number; anr: number }[];
}

export interface StabilityIssueSummary {
  fingerprint: string;
  kind: string;
  exception_type: string;
  sample_message: string;
  sample_stack: string;
  occurrence_count: number;
  user_count: number;
  first_seen_at: string;
  last_seen_at: string;
  status: string;
}

export interface StabilityEventRecord {
  event_id: string;
  kind: string;
  fingerprint: string;
  exception_type: string;
  message: string;
  stack: string;
  thread: string;
  is_fatal: boolean;
  blocked_ms?: number | null;
  anr_source?: string | null;
  app_version: string;
  app_build: string;
  device_model: string;
  device_os_version: string;
  user_id: string;
  event_time: string;
  received_at: string;
}

export interface StabilityIssueDetail {
  issue: StabilityIssueSummary;
  events: StabilityEventRecord[];
  total: number;
}
