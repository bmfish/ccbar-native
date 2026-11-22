alter table push_task add column task_type varchar(20) not null default 'TEXT'
    check (task_type in ('TEXT', 'WEIGHT', 'TOKEN_USAGE'));

alter table push_task add column last_body text not null default '';

insert into push_task (
    name, enabled, bark_url, title, messages, group_name, schedule_type,
    interval_minutes, daily_time, active_start, active_end, task_type
)
select '体重播报', true, bark_url, '体重播报', '', 'ccbar', 'DAILY',
       60, '08:30', '09:00', '18:00', 'WEIGHT'
from push_task
where bark_url <> ''
  and not exists (select 1 from push_task where task_type = 'WEIGHT')
order by id
limit 1;

insert into push_task (
    name, enabled, bark_url, title, messages, group_name, schedule_type,
    interval_minutes, daily_time, active_start, active_end, task_type
)
select 'Token 用量', true, bark_url, '今日 Token 用量', '', 'ccbar', 'DAILY',
       60, '22:00', '09:00', '18:00', 'TOKEN_USAGE'
from push_task
where bark_url <> ''
  and not exists (select 1 from push_task where task_type = 'TOKEN_USAGE')
order by id
limit 1;
