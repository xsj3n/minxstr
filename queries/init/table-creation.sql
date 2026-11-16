create schema if not exists nix;
--
create table if not exists nix.machines(
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_name text not null,
    assigned_cert text not null,
    hardware_fingerprint text not null,
    enabled boolean not null default true,
    compliant boolean not null default false,
    created_at timestamptz not null default now(),
    unique (assigned_cert, hardware_fingerprint)
);
--
create table if not exists nix.machine_actions(
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    machine_id bigint not null references nix.machines(id) on delete cascade,
    action_type text not null,
    payload text
);
--
create table if not exists nix.machine_info(
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    machine_id bigint not null references nix.machines(id) on delete cascade,
    assigned_user text
 );
--
create table if not exists nix.enrollment_tokens(
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    token_hash bytea not null unique,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default now() + interval '1 hour',
    used_at timestamptz,
    revoked_at timestamptz
);
--
create index if not exists idx_machine_actions_machine_id on nix.machine_actions(machine_id);
--
create unique index if not exists idx_machines_device_name on nix.machines(device_name);
