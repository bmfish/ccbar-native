create table trae_quota_snapshot (
    user_id bigint not null references app_user(id) on delete cascade,
    account varchar(200) not null,
    snapshot_date date not null,
    consumed_credits double precision not null default 0,
    total_credits double precision not null default 0,
    reported_at timestamptz not null,
    created_at timestamptz not null default now(),
    primary key (user_id, account, snapshot_date)
);

create index trae_quota_snapshot_lookup_idx
    on trae_quota_snapshot (user_id, account, snapshot_date desc);
