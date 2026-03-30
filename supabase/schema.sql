-- Run this whole file in the Supabase SQL editor.
-- It is written to be upgrade-friendly for projects that already have
-- an earlier version of the 75 Medium schema.
-- v2: adds per-user data isolation (user_id on every data table).

create extension if not exists pgcrypto;

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  owner_user_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

alter table public.workspace_members
add column if not exists role text not null default 'member';

alter table public.workspace_members
drop constraint if exists workspace_members_role_check;

alter table public.workspace_members
add constraint workspace_members_role_check
check (role in ('owner', 'member'));

create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  email text not null,
  role text not null default 'member',
  status text not null default 'pending',
  invited_by uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);

alter table public.invites
add column if not exists role text not null default 'member';

alter table public.invites
add column if not exists status text not null default 'pending';

alter table public.invites
add column if not exists accepted_at timestamptz;

alter table public.invites
drop constraint if exists invites_role_check;

alter table public.invites
add constraint invites_role_check
check (role in ('member'));

alter table public.invites
drop constraint if exists invites_status_check;

alter table public.invites
add constraint invites_status_check
check (status in ('pending', 'accepted', 'revoked'));

create unique index if not exists invites_workspace_email_status_idx
on public.invites (workspace_id, email, status);

-- ─── habit_entries ────────────────────────────────────────────────────────────
-- v2: primary key now includes user_id for per-user isolation.
-- If upgrading from v1, the old PK must be dropped first.

do $$
begin
  -- Add user_id column if it doesn't exist yet
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'habit_entries'
      and column_name  = 'user_id'
  ) then
    alter table public.habit_entries add column user_id uuid references auth.users(id) on delete cascade;
    -- Back-fill from updated_by for any existing rows
    update public.habit_entries set user_id = updated_by where user_id is null and updated_by is not null;
  end if;

  -- Re-create primary key to include user_id (idempotent)
  if exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public'
      and table_name   = 'habit_entries'
      and constraint_type = 'PRIMARY KEY'
  ) then
    -- Drop old PK (may or may not include user_id)
    execute (
      select 'alter table public.habit_entries drop constraint ' || quote_ident(constraint_name)
      from information_schema.table_constraints
      where table_schema = 'public'
        and table_name   = 'habit_entries'
        and constraint_type = 'PRIMARY KEY'
      limit 1
    );
  end if;

  alter table public.habit_entries
  add constraint habit_entries_pkey
  primary key (workspace_id, entry_date, habit_key, user_id);
end;
$$ language plpgsql;

create table if not exists public.habit_entries (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  entry_date date not null,
  habit_key text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  checked boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, entry_date, habit_key, user_id)
);

-- ─── nutrition_entries ────────────────────────────────────────────────────────

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'nutrition_entries'
      and column_name  = 'user_id'
  ) then
    alter table public.nutrition_entries add column user_id uuid references auth.users(id) on delete cascade;
    update public.nutrition_entries set user_id = created_by where user_id is null and created_by is not null;
  end if;
end;
$$ language plpgsql;

create table if not exists public.nutrition_entries (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_date date not null,
  meal text not null,
  name text not null,
  calories numeric not null default 0,
  protein numeric not null default 0,
  carbs numeric not null default 0,
  fat numeric not null default 0,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);

-- ─── meal_plans ───────────────────────────────────────────────────────────────
-- v2: primary key now includes user_id.

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'meal_plans'
      and column_name  = 'user_id'
  ) then
    alter table public.meal_plans add column user_id uuid references auth.users(id) on delete cascade;
    update public.meal_plans set user_id = created_by where user_id is null and created_by is not null;
  end if;

  -- Re-create primary key to include user_id
  if exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public'
      and table_name   = 'meal_plans'
      and constraint_type = 'PRIMARY KEY'
  ) then
    execute (
      select 'alter table public.meal_plans drop constraint ' || quote_ident(constraint_name)
      from information_schema.table_constraints
      where table_schema = 'public'
        and table_name   = 'meal_plans'
        and constraint_type = 'PRIMARY KEY'
      limit 1
    );
  end if;

  alter table public.meal_plans
  add constraint meal_plans_pkey
  primary key (workspace_id, week_start, user_id);
end;
$$ language plpgsql;

create table if not exists public.meal_plans (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  raw_text text not null,
  structured jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, week_start, user_id)
);

-- ─── Row Level Security ───────────────────────────────────────────────────────

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.invites enable row level security;
alter table public.habit_entries enable row level security;
alter table public.nutrition_entries enable row level security;
alter table public.meal_plans enable row level security;

drop policy if exists "workspace owners can read their workspaces" on public.workspaces;
drop policy if exists "workspace members can read workspaces" on public.workspaces;
drop policy if exists "workspace owners can update their workspaces" on public.workspaces;
drop policy if exists "workspace owners can update workspaces" on public.workspaces;

drop policy if exists "members can read workspace memberships" on public.workspace_members;
drop policy if exists "service functions manage memberships" on public.workspace_members;
drop policy if exists "owners can manage workspace memberships" on public.workspace_members;

drop policy if exists "owners can read invites" on public.invites;
drop policy if exists "owners can manage invites" on public.invites;

drop policy if exists "members can read habit entries" on public.habit_entries;
drop policy if exists "members can write habit entries" on public.habit_entries;
drop policy if exists "users can read own habit entries" on public.habit_entries;
drop policy if exists "users can write own habit entries" on public.habit_entries;

drop policy if exists "members can read nutrition entries" on public.nutrition_entries;
drop policy if exists "members can write nutrition entries" on public.nutrition_entries;
drop policy if exists "users can read own nutrition entries" on public.nutrition_entries;
drop policy if exists "users can write own nutrition entries" on public.nutrition_entries;

drop policy if exists "members can read meal plans" on public.meal_plans;
drop policy if exists "members can write meal plans" on public.meal_plans;
drop policy if exists "users can read own meal plans" on public.meal_plans;
drop policy if exists "users can write own meal plans" on public.meal_plans;

drop function if exists public.create_workspace_for_me(text);
drop function if exists public.join_workspace_by_code(text);
drop function if exists public.accept_my_pending_invites();
drop function if exists public.my_workspace_context();
drop function if exists public.workspace_role(uuid);
drop function if exists public.is_workspace_owner(uuid);
drop function if exists public.is_workspace_member(uuid);

create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id = target_workspace
      and wm.user_id = auth.uid()
  );
$$;

create or replace function public.workspace_role(target_workspace uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select wm.role
  from public.workspace_members wm
  where wm.workspace_id = target_workspace
    and wm.user_id = auth.uid()
  limit 1;
$$;

create or replace function public.is_workspace_owner(target_workspace uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id = target_workspace
      and wm.user_id = auth.uid()
      and wm.role = 'owner'
  );
$$;

create or replace function public.create_workspace_for_me(workspace_name text)
returns table(workspace_id uuid, invite_code text, member_role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_workspace public.workspaces;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  insert into public.workspaces (name, owner_user_id)
  values (coalesce(nullif(trim(workspace_name), ''), 'Shared 75 Medium Workspace'), auth.uid())
  returning * into new_workspace;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (new_workspace.id, auth.uid(), 'owner')
  on conflict on constraint workspace_members_pkey do update
  set role = excluded.role;

  return query
  select new_workspace.id, new_workspace.invite_code, 'owner'::text;
end;
$$;

create or replace function public.join_workspace_by_code(input_code text)
returns table(workspace_id uuid, workspace_name text, invite_code text, member_role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_workspace public.workspaces;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select *
  into target_workspace
  from public.workspaces
  where invite_code = upper(trim(input_code))
  limit 1;

  if target_workspace.id is null then
    raise exception 'Workspace not found';
  end if;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (target_workspace.id, auth.uid(), 'member')
  on conflict on constraint workspace_members_pkey do nothing;

  return query
  select target_workspace.id, target_workspace.name, target_workspace.invite_code, coalesce(public.workspace_role(target_workspace.id), 'member');
end;
$$;

create or replace function public.accept_my_pending_invites()
returns table(workspace_id uuid, workspace_name text, invite_code text, member_role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  auth_email text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  auth_email := lower(coalesce(auth.jwt() ->> 'email', ''));

  if auth_email = '' then
    return;
  end if;

  insert into public.workspace_members (workspace_id, user_id, role)
  select i.workspace_id, auth.uid(), i.role
  from public.invites i
  where lower(i.email) = auth_email
    and i.status = 'pending'
  on conflict on constraint workspace_members_pkey do nothing;

  update public.invites
  set status = 'accepted',
      accepted_at = now()
  where lower(email) = auth_email
    and status = 'pending';

  return query
  select w.id, w.name, w.invite_code, coalesce(public.workspace_role(w.id), 'member')
  from public.workspaces w
  join public.workspace_members wm on wm.workspace_id = w.id
  where wm.user_id = auth.uid()
  order by case when wm.role = 'owner' then 0 else 1 end, w.created_at;
end;
$$;

create or replace function public.my_workspace_context()
returns table(workspace_id uuid, workspace_name text, invite_code text, member_role text)
language sql
security definer
set search_path = public
as $$
  select w.id, w.name, w.invite_code, wm.role
  from public.workspaces w
  join public.workspace_members wm on wm.workspace_id = w.id
  where wm.user_id = auth.uid()
  order by case when wm.role = 'owner' then 0 else 1 end, w.created_at
  limit 1;
$$;

-- ─── Workspace policies ───────────────────────────────────────────────────────

create policy "workspace members can read workspaces"
on public.workspaces
for select
to authenticated
using (public.is_workspace_member(id));

create policy "workspace owners can update workspaces"
on public.workspaces
for update
to authenticated
using (public.is_workspace_owner(id))
with check (public.is_workspace_owner(id));

create policy "members can read workspace memberships"
on public.workspace_members
for select
to authenticated
using (public.is_workspace_member(workspace_id));

create policy "owners can manage workspace memberships"
on public.workspace_members
for all
to authenticated
using (public.is_workspace_owner(workspace_id))
with check (public.is_workspace_owner(workspace_id));

create policy "owners can read invites"
on public.invites
for select
to authenticated
using (public.is_workspace_owner(workspace_id));

create policy "owners can manage invites"
on public.invites
for all
to authenticated
using (public.is_workspace_owner(workspace_id))
with check (public.is_workspace_owner(workspace_id));

-- ─── habit_entries policies (per-user isolation) ──────────────────────────────

-- Read: must be a workspace member AND the row belongs to you
create policy "users can read own habit entries"
on public.habit_entries
for select
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);

-- Write: must be a workspace member AND inserting/updating your own rows only
create policy "users can write own habit entries"
on public.habit_entries
for all
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
)
with check (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);

-- ─── nutrition_entries policies (per-user isolation) ──────────────────────────

create policy "users can read own nutrition entries"
on public.nutrition_entries
for select
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);

create policy "users can write own nutrition entries"
on public.nutrition_entries
for all
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
)
with check (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);

-- ─── meal_plans policies (per-user isolation) ─────────────────────────────────

create policy "users can read own meal plans"
on public.meal_plans
for select
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);

create policy "users can write own meal plans"
on public.meal_plans
for all
to authenticated
using (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
)
with check (
  public.is_workspace_member(workspace_id)
  and user_id = auth.uid()
);
