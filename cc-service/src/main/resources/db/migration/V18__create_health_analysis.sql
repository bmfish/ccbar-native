-- 健康数据 AI 分析结果缓存：单行表。
-- 以数据指纹（样本条数 + 最大 updated_at）判断是否复用：健康数据无变化时不调用 LLM。
create table health_analysis (
    id integer primary key default 1 check (id = 1),
    fingerprint varchar(64) not null default '',
    days integer not null default 30,
    model varchar(64) not null default '',
    result jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now()
);

insert into health_analysis (id) values (1) on conflict (id) do nothing;
