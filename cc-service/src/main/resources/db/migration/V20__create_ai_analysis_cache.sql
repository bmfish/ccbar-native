-- AI 分析缓存泛化：原健康分析缓存扩展为按 domain 键的通用缓存（health / usage / trae / travel）。
-- 每个板块一行，数据指纹变化才重新调用 LLM。
create table ai_analysis_cache (
    domain varchar(32) primary key,
    fingerprint varchar(64) not null default '',
    days integer not null default 30,
    model varchar(64) not null default '',
    result jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now()
);

insert into ai_analysis_cache (domain, fingerprint, days, model, result)
select 'health', fingerprint, days, model, result from health_analysis;

drop table health_analysis;
