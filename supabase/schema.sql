-- Run this in the Supabase SQL editor.
-- This schema adds shared persistence for the 75 Medium app.

create extension if not exists pgcrypto;

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table if not exists public.habit_entries (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  entry_date date not null,
  habit_key text not null,
  checked boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, entry_date, habit_key)
);

create table if not exists public.nutrition_entries (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
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

create table if not exists public.meal_plans (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  week_start date not null,
  raw_text text not null,
  structured jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, week_start)
);

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.habit_entries enable row level security;
alter table public.nutrition_entries enable row level security;
alter table public.meal_plans enable row level security;

create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id = target_workspace
      and wm.user_id = auth.uid()
  );
$$;

create or replace function public.create_workspace_for_me(workspace_name text)
returns table(workspace_id uuid, invite_code text)
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

  insert into public.workspace_members (workspace_id, user_id)
  values (new_workspace.id, auth.uid())
  on conflict do nothing;

  return query
  select new_workspace.id, new_workspace.invite_code;
end;
$$;

create or replace function public.join_workspace_by_code(input_code text)
returns table(workspace_id uuid, workspace_name text, invite_code text)
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

  insert into public.workspace_members (workspace_id, user_id)
  values (target_workspace.id, auth.uid())
  on conflict do nothing;

  return query
  select target_workspace.id, target_workspace.name, target_workspace.invite_code;
end;
$$;

create policy "workspace owners can read their workspaces"
on public.workspaces
for select
to authenticated
using (public.is_workspace_member(id));

create policy "workspace owners can update their workspaces"
on public.workspaces
for update
to authenticated
using (owner_user_id = auth.uid())
with check (owner_user_id = auth.uid());

create policy "members can read workspace memberships"
on public.workspace_members
for select
to authenticated
using (public.is_workspace_member(workspace_id));

create policy "service functions manage memberships"
on public.workspace_members
for insert
to authenticated
with check (user_id = auth.uid());

create policy "members can read habit entries"
on public.habit_entries
for select
to authenticated
using (public.is_workspace_member(workspace_id));

create policy "members can write habit entries"
on public.habit_entries
for all
to authenticated
using (public.is_workspace_member(workspace_id))
with check (public.is_workspace_member(workspace_id));

create policy "members can read nutrition entries"
on public.nutrition_entries
for select
to authenticated
using (public.is_workspace_member(workspace_id));

create policy "members can write nutrition entries"
on public.nutrition_entries
for all
to authenticated
using (public.is_workspace_member(workspace_id))
with check (public.is_workspace_member(workspace_id));

create policy "members can read meal plans"
on public.meal_plans
for select
to authenticated
using (public.is_workspace_member(workspace_id));

create policy "members can write meal plans"
on public.meal_plans
for all
to authenticated
using (public.is_workspace_member(workspace_id))
with check (public.is_workspace_member(workspace_id));

