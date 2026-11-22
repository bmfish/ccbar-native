create table push_setting (
    id smallint primary key default 1 check (id = 1),
    enabled boolean not null default false,
    bark_url varchar(500) not null default '',
    title varchar(100) not null default '久坐提醒',
    body varchar(500) not null default '起来活动一下，喝口水，看看远处。',
    group_name varchar(100) not null default '',
    interval_minutes int not null default 60 check (interval_minutes between 1 and 1440),
    active_start time not null default '09:00',
    active_end time not null default '18:00',
    last_sent_at timestamptz,
    last_status varchar(20),
    last_error varchar(500),
    updated_at timestamptz not null default now()
);

insert into push_setting (id) values (1);
