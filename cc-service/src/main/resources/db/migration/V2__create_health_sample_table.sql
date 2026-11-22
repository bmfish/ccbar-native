create table health_sample (
    id bigserial primary key,
    kind varchar(16) not null,
    recorded_at timestamptz not null,
    value double precision not null,
    source varchar(100),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint health_sample_kind_check check (kind in ('weight', 'bodyfat', 'height')),
    constraint health_sample_kind_recorded_at_key unique (kind, recorded_at)
);

create index health_sample_kind_recorded_at_idx on health_sample (kind, recorded_at desc);
