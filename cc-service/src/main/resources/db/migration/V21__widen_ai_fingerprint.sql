-- Trae 等组合指纹（两段 count+时间戳拼接）超过 varchar(64)，加宽到 256。
alter table ai_analysis_cache alter column fingerprint type varchar(256);
