create table push_task (
    id bigserial primary key,
    name varchar(100) not null,
    enabled boolean not null default true,
    bark_url varchar(500) not null,
    title varchar(100) not null,
    body varchar(500) not null,
    group_name varchar(100) not null default '',
    schedule_type varchar(20) not null default 'INTERVAL'
        check (schedule_type in ('INTERVAL', 'DAILY')),
    interval_minutes int not null default 60
        check (interval_minutes between 1 and 1440),
    daily_time time not null default '09:00',
    active_start time not null default '09:00',
    active_end time not null default '18:00',
    last_sent_at timestamptz,
    last_status varchar(20),
    last_error varchar(500),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index push_task_enabled_idx on push_task (enabled);

insert into push_task (
    name, enabled, bark_url, title, body, group_name,
    schedule_type, interval_minutes, active_start, active_end,
    last_sent_at, last_status, last_error
)
select title, enabled, bark_url, title, body, group_name,
       'INTERVAL', interval_minutes, active_start, active_end,
       last_sent_at, last_status, last_error
from push_setting
where id = 1 and bark_url <> '';

drop table push_setting;
