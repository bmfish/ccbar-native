alter table push_task add column messages text not null default '';

update push_task set messages = body where messages = '';

alter table push_task drop column body;
