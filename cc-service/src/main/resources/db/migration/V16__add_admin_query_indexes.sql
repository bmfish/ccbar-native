-- 先只加最关键的两个索引，避免 usage_event 写入放大。
-- 设备事件数索引 (user_id, device_id) 以及来源/Trae 索引，
-- 等 EXPLAIN / pg_stat_statements 确认后再按需补。
create index if not exists usage_event_user_created_idx
    on usage_event (user_id, created_at);

create index if not exists user_device_last_seen_idx
    on user_device (last_seen_at);
