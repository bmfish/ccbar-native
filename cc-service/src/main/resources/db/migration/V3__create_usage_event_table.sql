create sequence if not exists usage_event_seq;

create table usage_event (
    source varchar(64) not null,
    request_id varchar(400) not null,
    app_type varchar(100),
    model varchar(200),
    input_tokens bigint not null default 0,
    output_tokens bigint not null default 0,
    cache_read_tokens bigint not null default 0,
    cache_creation_tokens bigint not null default 0,
    reasoning_tokens bigint not null default 0,
    total_cost_usd double precision not null default 0,
    credits double precision not null default 0,
    request_count bigint not null default 1,
    account varchar(200) not null default '',
    device_id varchar(100),
    seq bigint not null default nextval('usage_event_seq'),
    created_at bigint not null,
    updated_at timestamptz not null default now(),
    primary key (source, request_id)
);

create index usage_event_seq_idx on usage_event (seq);
create index usage_event_created_at_idx on usage_event (created_at desc);
