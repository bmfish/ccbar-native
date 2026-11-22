create table trae_account_quota (
    user_id bigint not null references app_user(id) on delete cascade,
    account varchar(200) not null,
    slot int,
    consumed_credits double precision not null default 0,
    total_credits double precision not null default 0,
    reported_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (user_id, account)
);

create index trae_account_quota_updated_idx on trae_account_quota (updated_at desc);
