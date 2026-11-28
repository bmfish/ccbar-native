-- AI 分析缓存主键改为 (domain, days)：不同统计天数各自缓存，来回切换不再互相踢掉重调 LLM。
alter table ai_analysis_cache drop constraint ai_analysis_cache_pkey;
alter table ai_analysis_cache add primary key (domain, days);
