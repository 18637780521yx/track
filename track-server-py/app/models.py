from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class TrackEvent(BaseModel):
    event_id: str = ""
    name: str = ""
    properties: Dict[str, Any] = Field(default_factory=dict)
    common_properties: Dict[str, Any] = Field(default_factory=dict)
    distinct_id: Optional[str] = None
    anonymous_id: str = ""
    session_id: str = ""
    timestamp: Optional[datetime] = None


class IngestResponse(BaseModel):
    ok: bool = True
    total: int
    stored: int
    dropped: int


class NamedCount(BaseModel):
    name: str
    count: int


class DailyEventStat(BaseModel):
    date: str
    count: int = 0
    users: int = 0
    new_users: int = 0
    installs: int = 0
    revenue: float = 0.0
    active_subscriptions: int = 0


class OverviewStats(BaseModel):
    dau: int = 0
    new_users: int = 0
    installs: int = 0
    revenue: float = 0.0
    paying_users: int = 0
    active_subscriptions: int = 0
    total_events: int = 0
    top_events: List[NamedCount] = Field(default_factory=list)
    trend: List[DailyEventStat] = Field(default_factory=list)


class EventTrendPoint(BaseModel):
    bucket: str
    count: int
    users: int


class EventRecord(BaseModel):
    event_id: str
    name: str
    properties: Dict[str, Any] = Field(default_factory=dict)
    common_properties: Dict[str, Any] = Field(default_factory=dict)
    distinct_id: Optional[str] = None
    anonymous_id: str
    session_id: str
    event_time: datetime
    received_at: datetime


class FunnelStep(BaseModel):
    name: str
    users: int
    conversion: float


class FunnelResult(BaseModel):
    steps: List[FunnelStep] = Field(default_factory=list)


class FunnelRequest(BaseModel):
    steps: List[str] = Field(default_factory=list)
    from_: Optional[str] = Field(default=None, alias="from")
    to: Optional[str] = None
    window_hours: int = 24

    model_config = {"populate_by_name": True}


class RetentionRow(BaseModel):
    cohort_date: str
    cohort_size: int
    retention: List[float]


class RetentionResult(BaseModel):
    days: List[int]
    rows: List[RetentionRow] = Field(default_factory=list)


class UserRecord(BaseModel):
    user_id: str
    distinct_id: Optional[str] = None
    anonymous_id: str
    first_seen_at: datetime
    last_seen_at: datetime
    first_open_at: Optional[datetime] = None
    signup_at: Optional[datetime] = None
    is_paid: bool = False
    total_revenue: float = 0.0
    channel: Optional[str] = None


class EventFilter(BaseModel):
    source: str = "common"
    field: str = ""
    op: str = "eq"
    value: str = ""


class StabilityTrendPoint(BaseModel):
    date: str
    crash: int = 0
    error: int = 0
    anr: int = 0


class StabilityOverview(BaseModel):
    crash: int = 0
    error: int = 0
    anr: int = 0
    issue_count: int = 0
    affected_users: int = 0
    trend: List[StabilityTrendPoint] = Field(default_factory=list)


class StabilityIssueSummary(BaseModel):
    fingerprint: str
    kind: str
    exception_type: str = ""
    sample_message: str = ""
    sample_stack: str = ""
    occurrence_count: int = 0
    user_count: int = 0
    first_seen_at: datetime
    last_seen_at: datetime
    status: str = "open"


class StabilityEventRecord(BaseModel):
    event_id: str
    kind: str
    fingerprint: str
    exception_type: str = ""
    message: str = ""
    stack: str = ""
    thread: str = ""
    is_fatal: bool = False
    blocked_ms: Optional[int] = None
    anr_source: Optional[str] = None
    app_version: str = ""
    app_build: str = ""
    device_model: str = ""
    device_os_version: str = ""
    distinct_id: Optional[str] = None
    anonymous_id: str = ""
    session_id: str = ""
    user_id: str = ""
    extras: Dict[str, Any] = Field(default_factory=dict)
    event_time: datetime
    received_at: datetime


class StabilityIssueDetail(BaseModel):
    issue: StabilityIssueSummary
    events: List[StabilityEventRecord] = Field(default_factory=list)
    total: int = 0
