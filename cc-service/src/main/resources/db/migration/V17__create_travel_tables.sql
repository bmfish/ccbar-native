-- 旅行票据：12306 订票邮件同步（高铁笔记 iOS App 的服务端移植）。
-- 单向数据流：QQ 邮箱 IMAP → 解析购票/改签/退票邮件 → 候选票根 → 确认后转正式票根。

-- 正式票根（trip_key 全局去重：车次|出发|到达|yyyy.MM.dd）
create table travel_ticket (
    id bigserial primary key,
    trip_key varchar(128) not null unique,
    ride_date date not null,
    depart_time varchar(8),
    train_no varchar(16),
    from_station varchar(64),
    to_station varchar(64),
    coach varchar(16),
    seat varchar(16),
    seat_class varchar(32),
    price numeric(10, 2),
    passenger varchar(64),
    status varchar(16) not null default 'normal',   -- normal / refunded / changed
    note text,
    source varchar(16) not null default '12306',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index travel_ticket_ride_date_idx on travel_ticket (ride_date desc);
create index travel_ticket_route_idx on travel_ticket (from_station, to_station);
create index travel_ticket_passenger_idx on travel_ticket (passenger);

-- 邮件解析出的候选票根，要素齐全可自动导入，残缺的留待管理台人工确认/忽略
create table travel_mail_candidate (
    id bigserial primary key,
    trip_key varchar(128) not null unique,
    ride_date date,
    depart_time_text varchar(8),
    train_no varchar(16),
    from_station varchar(64),
    to_station varchar(64),
    coach varchar(16),
    seat varchar(16),
    seat_class varchar(32),
    price numeric(10, 2),
    passenger varchar(64),
    order_no varchar(32),
    source varchar(16) not null default '12306',
    imported boolean not null default false,
    dismissed boolean not null default false,
    fetched_at timestamptz not null default now()
);

create index travel_mail_candidate_pending_idx on travel_mail_candidate (imported, dismissed, fetched_at);

-- 同步水位与状态（单行表）
create table travel_sync_state (
    id integer primary key default 1 check (id = 1),
    email varchar(128),
    owner varchar(64),
    last_sync_at timestamptz,
    last_full_sync_at timestamptz,
    last_result jsonb,
    updated_at timestamptz not null default now()
);

insert into travel_sync_state (id) values (1) on conflict (id) do nothing;
