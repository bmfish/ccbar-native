create table api_audit_log (
    id bigserial primary key,
    user_id bigint references app_user(id) on delete set null,
    method varchar(10) not null,
    path varchar(255) not null,
    status int not null,
    duration_ms int not null,
    ip varchar(64) not null default '',
    user_agent varchar(255) not null default '',
    created_at timestamptz not null default now()
);

create index api_audit_log_created_idx on api_audit_log (created_at desc);
create index api_audit_log_path_idx on api_audit_log (path, created_at desc);
create index api_audit_log_user_idx on api_audit_log (user_id, created_at desc);
create index api_audit_log_status_idx on api_audit_log (status, created_at desc);
