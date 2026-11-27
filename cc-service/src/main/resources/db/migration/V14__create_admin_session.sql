create table admin_session (
    token_hash char(64) primary key,
    username varchar(64) not null,
    created_at timestamptz not null default now(),
    last_used_at timestamptz,
    expires_at timestamptz not null
);

create index admin_session_expires_idx on admin_session (expires_at);
