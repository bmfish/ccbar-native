-- 推送任务新增 AI_BRIEFING 类型：每日把四个板块的 AI 综合简报推送到 Bark。
alter table push_task drop constraint push_task_task_type_check;
alter table push_task add constraint push_task_task_type_check
    check (task_type in ('TEXT', 'WEIGHT', 'TOKEN_USAGE', 'AI_BRIEFING'));
