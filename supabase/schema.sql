-- COOL NAME PENDING: database schema for Supabase.
-- Run once in the Supabase SQL editor. Safe to re-run.
-- Every table is readable and writable only by members of the group;
-- people become members by entering the group code (join_group).

create table if not exists public.members (
  user_id uuid primary key references auth.users on delete cascade,
  joined_at timestamptz not null default now()
);

-- Holds the group code. RLS on and no policies: unreachable through the API.
create table if not exists public.secrets (
  key text primary key,
  value text not null
);

alter table public.members enable row level security;
alter table public.secrets enable row level security;

drop policy if exists own_membership on public.members;
create policy own_membership on public.members
  for select to authenticated using (user_id = auth.uid());

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid());
$$;

drop function if exists public.join_group(text);
create function public.join_group(code text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return 'no_user'; end if;
  if exists (select 1 from secrets where key = 'group_code' and value = lower(trim(code))) then
    insert into members (user_id) values (auth.uid()) on conflict do nothing;
    return 'ok';
  end if;
  return 'bad_code';
end;
$$;

revoke all on function public.join_group(text) from public;
grant execute on function public.join_group(text) to authenticated;
grant execute on function public.is_member() to authenticated;

-- App data: one row per document, fields in jsonb.
do $$
declare t text;
begin
  foreach t in array array['friends', 'quotes', 'votes'] loop
    execute format('create table if not exists public.%I (id text primary key, data jsonb not null default ''{}''::jsonb, updated_at timestamptz not null default now())', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists members_all on public.%I', t);
    execute format('create policy members_all on public.%I for all to authenticated using (public.is_member()) with check (public.is_member())', t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
