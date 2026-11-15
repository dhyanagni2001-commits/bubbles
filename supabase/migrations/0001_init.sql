create table profiles (
  id uuid primary key default gen_random_uuid(),
  device_id text unique not null,
  name text not null,
  avatar_url text,
  version int not null default 1,
  updated_at timestamptz default now()
);
create table profile_lines (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles on delete cascade,
  kind text check (kind in ('ask','offer','identity','looking_for','plan')),
  text text not null,
  source text check (source in ('interview','calendar','manual')),
  expires_at timestamptz,
  is_public boolean default true
);
create table ble_tokens (
  token text primary key,
  profile_id uuid references profiles on delete cascade,
  expires_at timestamptz not null
);
create table matches (
  viewer_id uuid, target_id uuid,
  viewer_version int, target_version int,
  sentence text, kind text, score int,
  created_at timestamptz default now(),
  primary key (viewer_id, target_id)
);
create table waves (
  id uuid primary key default gen_random_uuid(),
  from_id uuid, to_id uuid, sentence text,
  created_at timestamptz default now(), seen_at timestamptz
);
create table catches (
  owner_id uuid, target_id uuid, sentence text, score int, rarity text,
  created_at timestamptz default now(),
  primary key (owner_id, target_id)
);
-- Hackathon: permissive access for the anon key. Tighten later.
do $$ declare t text; begin
  foreach t in array array['profiles','profile_lines','ble_tokens','matches','waves','catches'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy anon_all on %I for all using (true) with check (true)', t);
  end loop;
end $$;
alter publication supabase_realtime add table waves;
