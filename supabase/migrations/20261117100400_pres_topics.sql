-- ADIAK 1.2 / item 9: topic lists for presentations.
-- The teacher creates a presentation with a title and uploads a TXT/DOCX topic list. The app reads the file in the browser and
-- sends the parsed lines; the server validates them again (trim, numbering/bullets removed, 1..200 chars, duplicates ignored,
-- max 300 per presentation). Students of participating teams pick one topic each; topic_max limits how many students may
-- share a topic (1 = exclusive, 0 = unlimited). Staff see who picked what, edit/remove topics, change the limit and release picks.
-- Picks are locked once the event is frozen (live/done). Additive only.
-- Rollback: supabase/rollback/v12_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regclass('public.pres_topics') is not null then raise exception 'pre-flight: item9 already applied'; end if;
  if to_regclass('public.pres_events') is null then raise exception 'pre-flight: M2 missing'; end if;
end $$;

alter table public.pres_events add column if not exists topic_max int not null default 1 check (topic_max between 0 and 50);
alter table public.pres_events add column if not exists topics_source text check (topics_source is null or char_length(topics_source) <= 120);

create table public.pres_topics (
  id bigint generated always as identity primary key,
  event_id bigint not null references public.pres_events (id),
  title text not null check (char_length(title) between 1 and 200),
  position int not null,
  created_by uuid, created_at timestamptz not null default now(),
  removed_at timestamptz, removed_by uuid
);
create unique index pres_topics_title on public.pres_topics (event_id, lower(title)) where removed_at is null;
create index pres_topics_event on public.pres_topics (event_id, position);

create table public.pres_topic_picks (
  event_id bigint not null references public.pres_events (id),
  user_id uuid not null references public.profiles (id) on delete cascade,
  topic_id bigint not null references public.pres_topics (id),
  group_id bigint,
  user_name text not null,
  picked_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index pres_topic_picks_topic on public.pres_topic_picks (topic_id);

alter table public.pres_topics enable row level security;
alter table public.pres_topic_picks enable row level security;
create policy r on public.pres_topics for select to authenticated using (public._pres_class(event_id));
create policy r on public.pres_topic_picks for select to authenticated using (public._pres_class(event_id));
revoke all on public.pres_topics, public.pres_topic_picks from public, anon, authenticated;
grant select on public.pres_topics, public.pres_topic_picks to authenticated;

-- normalise one line of a topic list: bullets / "1." / "1)" / "a)" removed, whitespace collapsed
create or replace function public._pres_topic_clean(s text) returns text
 language sql immutable set search_path = pg_catalog as $$
  select nullif(left(btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(s, ''), '[[:cntrl:]]+', ' ', 'g'),
     '^\s*([-*•·–—▪●○◦]+\s*|\(?[0-9]{1,3}[.):\]]+\s*|[0-9]{1,3}\s+[-–—]\s+|[a-zA-Z][.)]\s+)', ''), '\s+', ' ', 'g')), 200), '') $$;

create or replace function public.pres_topics_add(e bigint, items text[], src text default null) returns int
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare ev public.pres_events := public._pres_event_for_staff(e, true); u uuid := auth.uid(); n int := 0; p int; x text; c text; have int;
begin
  perform public._rate('topics', 30, 600);
  if ev.status = 'done' then raise exception 'The presentation is finished'; end if;
  if items is null or array_length(items, 1) is null then raise exception 'The file has no topics'; end if;
  if array_length(items, 1) > 1000 then raise exception 'Too many lines in the file (max 1000)'; end if;
  select coalesce(max(position), 0), count(*) filter (where removed_at is null) into p, have from public.pres_topics where event_id = e;
  foreach x in array items loop
    c := public._pres_topic_clean(x);
    continue when c is null;
    continue when exists (select 1 from public.pres_topics where event_id = e and removed_at is null and lower(title) = lower(c));
    if have + n >= 300 then raise exception 'A presentation can have at most 300 topics'; end if;
    p := p + 1; n := n + 1;
    insert into public.pres_topics (event_id, title, position, created_by) values (e, c, p, u);
  end loop;
  if n = 0 and have = 0 then raise exception 'The file has no topics'; end if;
  if src is not null then update public.pres_events set topics_source = left(regexp_replace(trim(src), '[[:cntrl:]/\\]+', '_', 'g'), 120), updated_at = now() where id = e; end if;
  if n > 0 and ev.status <> 'draft' then
    perform public._notify(public._pres_event_ids(e), 'pres.topics', jsonb_build_object('title', ev.title, 'n', n),
      jsonb_build_object('k', 'pres', 'event', e, 'sec', 'overview'), 'topics:' || e || ':' || extract(epoch from now())::bigint);
  end if;
  return n;
end $$;

create or replace function public.pres_topic_edit(tid bigint, ttl text) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pres_topics; c text := public._pres_topic_clean(ttl);
begin
  select * into t from public.pres_topics where id = tid and removed_at is null;
  if not found then raise exception 'Topic not found'; end if;
  perform public._pres_event_for_staff(t.event_id, true);
  if c is null then raise exception 'Topic must be 1 to 200 characters'; end if;
  if exists (select 1 from public.pres_topics where event_id = t.event_id and id <> tid and removed_at is null and lower(title) = lower(c)) then
    raise exception 'This topic is already in the list'; end if;
  update public.pres_topics set title = c where id = tid;
end $$;

create or replace function public.pres_topic_remove(tid bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pres_topics; ev public.pres_events; who uuid[];
begin
  select * into t from public.pres_topics where id = tid and removed_at is null for update;
  if not found then raise exception 'Topic not found'; end if;
  ev := public._pres_event_for_staff(t.event_id, true);
  select array_agg(user_id) into who from public.pres_topic_picks where topic_id = tid;
  delete from public.pres_topic_picks where topic_id = tid;
  update public.pres_topics set removed_at = now(), removed_by = auth.uid() where id = tid;
  if who is not null then
    perform public._notify(who, 'pres.topic_released', jsonb_build_object('title', ev.title, 'topic', t.title),
      jsonb_build_object('k', 'pres', 'event', t.event_id, 'sec', 'overview'), 'trel:' || tid);
  end if;
end $$;

create or replace function public.pres_topic_limit(e bigint, n int) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare ev public.pres_events := public._pres_event_for_staff(e, true); worst int;
begin
  if n is null or n not between 0 and 50 then raise exception 'The limit must be 0 (unlimited) to 50'; end if;
  if n > 0 then
    select max(c) into worst from (select count(*) c from public.pres_topic_picks where event_id = e group by topic_id) x;
    if coalesce(worst, 0) > n then raise exception 'Some topics already have more students than that (%)', worst; end if;
  end if;
  update public.pres_events set topic_max = n, updated_at = now() where id = e;
end $$;

create or replace function public.pres_topic_pick(tid bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); t public.pres_topics; ev public.pres_events; g bigint; n int; nm text;
begin
  perform public._rate('topic_pick', 30, 60);
  select * into t from public.pres_topics where id = tid and removed_at is null for update;
  if not found then raise exception 'Topic not found'; end if;
  select * into ev from public.pres_events where id = t.event_id;
  g := public._pres_my_group(t.event_id);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  if ev.frozen_at is not null then raise exception 'Topics are locked: the presentation is live or finished'; end if;
  if exists (select 1 from public.pres_topic_picks where event_id = t.event_id and user_id = u and topic_id = tid) then return; end if;
  if ev.topic_max > 0 then
    select count(*) into n from public.pres_topic_picks where topic_id = tid and user_id <> u;
    if n >= ev.topic_max then raise exception 'This topic is already taken'; end if;
  end if;
  select name into nm from public.profiles where id = u;
  insert into public.pres_topic_picks (event_id, user_id, topic_id, group_id, user_name) values (t.event_id, u, tid, g, nm)
  on conflict (event_id, user_id) do update set topic_id = excluded.topic_id, group_id = excluded.group_id, user_name = excluded.user_name, picked_at = now();
end $$;

create or replace function public.pres_topic_unpick(e bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok();
begin
  perform public._rate('topic_pick', 30, 60);
  if (select frozen_at from public.pres_events where id = e) is not null then raise exception 'Topics are locked: the presentation is live or finished'; end if;
  delete from public.pres_topic_picks where event_id = e and user_id = u;
end $$;

create or replace function public.pres_topic_release(e bigint, who uuid) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare ev public.pres_events := public._pres_event_for_staff(e, true); tt text;
begin
  select t.title into tt from public.pres_topic_picks p join public.pres_topics t on t.id = p.topic_id where p.event_id = e and p.user_id = who;
  if tt is null then return; end if;
  delete from public.pres_topic_picks where event_id = e and user_id = who;
  perform public._notify(array[who], 'pres.topic_released', jsonb_build_object('title', ev.title, 'topic', tt),
    jsonb_build_object('k', 'pres', 'event', e, 'sec', 'overview'), 'trel:' || e || ':' || who || ':' || extract(epoch from now())::bigint);
end $$;

revoke all on function public._pres_topic_clean(text) from public, anon, authenticated, service_role;
revoke all on function public.pres_topics_add(bigint, text[], text), public.pres_topic_edit(bigint, text), public.pres_topic_remove(bigint),
  public.pres_topic_limit(bigint, int), public.pres_topic_pick(bigint), public.pres_topic_unpick(bigint), public.pres_topic_release(bigint, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.pres_topics_add(bigint, text[], text), public.pres_topic_edit(bigint, text), public.pres_topic_remove(bigint),
  public.pres_topic_limit(bigint, int), public.pres_topic_pick(bigint), public.pres_topic_unpick(bigint), public.pres_topic_release(bigint, uuid)
  to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.pres_topics, public.pres_topic_picks;
  end if;
end $$;
