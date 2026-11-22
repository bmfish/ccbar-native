create table app_user (
    id bigserial primary key,
    username varchar(64) not null,
    password_hash varchar(255) not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint app_user_username_key unique (username)
);

create table user_token (
    token_hash char(64) primary key,
    user_id bigint not null references app_user(id) on delete cascade,
    created_at timestamptz not null default now(),
    last_used_at timestamptz
);

create index user_token_user_idx on user_token (user_id);

create table user_device (
    user_id bigint not null references app_user(id) on delete cascade,
    device_id varchar(100) not null,
    first_seen_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    primary key (user_id, device_id)
);

-- 现有单租户数据统一归属 default 用户，升级不丢数据
insert into app_user (username, password_hash)
values ('default', '')
on conflict (username) do nothing;

alter table usage_event add column user_id bigint;
update usage_event
set user_id = (select id from app_user where username = 'default')
where user_id is null;
alter table usage_event alter column user_id set not null;
alter table usage_event add constraint usage_event_user_fk
    foreign key (user_id) references app_user(id) on delete cascade;

alter table usage_event drop constraint usage_event_pkey;
alter table usage_event add primary key (user_id, source, request_id);

create index usage_event_user_seq_idx on usage_event (user_id, seq);
