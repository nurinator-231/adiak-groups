-- ADIAK 1.1 / item 6: chat read receipts ("Görüldü") and last-seen presence.
-- message_reads: one row per (channel, reader) with the highest message id the reader has seen. Written only through
--   mark_read() for channels the caller can access; readable by everyone who can access the channel; in the realtime
--   publication so receipts update live. The class-wide 'all' channel has no receipts (too many readers).
-- user_presence: last time a signed-in client was connected / active. Live online state comes from Realtime Presence
--   (dropped automatically when the socket closes or heartbeats stop); this table gives "last seen" for offline people.
--   presence_ping() is throttled server-side (one write per 30 s per user). Not in the realtime publication.
-- Additive only. Rollback: supabase/rollback/v11_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regclass('public.message_reads') is not null then raise exception 'pre-flight: item6 already applied'; end if;
end $$;

-- class B policy helpers (executable by authenticated, boolean only): the underlying checks are not client-executable
create or replace function public._chan_read(ch text) returns boolean
 language sql stable security definer set search_path = pg_catalog, public as $$
  select auth.uid() is not null and ch <> 'all' and public._chan_ok(ch, auth.uid()) $$;
create or replace function public._seen_ok(u uuid) returns boolean
 language sql stable security definer set search_path = pg_catalog, public as $$
  select auth.uid() is not null and (u = auth.uid() or public._can_see_user(u, auth.uid())) $$;
revoke all on function public._chan_read(text), public._seen_ok(uuid) from public, anon, authenticated, service_role;
grant execute on function public._chan_read(text), public._seen_ok(uuid) to authenticated;

create table public.message_reads (
  channel text not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  last_read_id bigint not null,
  read_at timestamptz not null default now(),
  primary key (channel, user_id)
);
create index message_reads_user on public.message_reads (user_id);
alter table public.message_reads enable row level security;
create policy r on public.message_reads for select to authenticated using (public._chan_read(channel));
revoke all on public.message_reads from public, anon, authenticated;
grant select on public.message_reads to authenticated;

create table public.user_presence (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  last_seen_at timestamptz not null default now(),
  last_active_at timestamptz
);
alter table public.user_presence enable row level security;
create policy r on public.user_presence for select to authenticated using (public._seen_ok(user_id));
revoke all on public.user_presence from public, anon, authenticated;
grant select on public.user_presence to authenticated;

create or replace function public.mark_read(ch text, mid bigint) returns bigint
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); top bigint; cur bigint;
begin
  if ch is null or ch = 'all' or mid is null then return null; end if;
  if not public._chan_ok(ch, u) then raise exception 'You cannot read this chat'; end if;
  select max(id) into top from public.messages where channel = ch and id <= mid;
  if top is null then return null; end if;
  select last_read_id into cur from public.message_reads where channel = ch and user_id = u;
  if cur is not null and cur >= top then return cur; end if;
  insert into public.message_reads (channel, user_id, last_read_id, read_at) values (ch, u, top, now())
  on conflict (channel, user_id) do update set last_read_id = greatest(public.message_reads.last_read_id, excluded.last_read_id), read_at = now();
  return top;
end $$;

create or replace function public.presence_ping(active boolean default true) returns timestamptz
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); n timestamptz := now();
begin
  insert into public.user_presence (user_id, last_seen_at, last_active_at) values (u, n, case when active then n end)
  on conflict (user_id) do update set last_seen_at = n,
     last_active_at = case when active then n else public.user_presence.last_active_at end
   where public.user_presence.last_seen_at < n - interval '30 seconds'
      or (active and coalesce(public.user_presence.last_active_at, '-infinity') < n - interval '30 seconds');
  return n;
end $$;

-- called when the app is closed/hidden or the user goes idle: "last seen" becomes exact (no throttle)
create or replace function public.presence_bye() returns void
 language sql security definer set search_path = pg_catalog, public as $$
  insert into public.user_presence (user_id, last_seen_at) select public._me_ok(), now()
  on conflict (user_id) do update set last_seen_at = now() $$;

revoke all on function public.mark_read(text, bigint), public.presence_ping(boolean), public.presence_bye() from public, anon, authenticated, service_role;
grant execute on function public.mark_read(text, bigint), public.presence_ping(boolean), public.presence_bye() to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.message_reads;
  end if;
end $$;
