create table note (
    id bigserial primary key,
    title varchar(200) not null,
    content text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
