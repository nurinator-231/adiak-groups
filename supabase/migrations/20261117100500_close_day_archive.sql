-- ADIAK 1.2 / item 8: "Günü bitir" archives the day's presentations together with the chats, atomically and without duplicates.
-- close_day(lbl, dissolve, cls):
--   · cls null  → admin only, whole platform (same scope as before for chats).
--     cls given → admin or a teacher of that class: the class chat, its group chats, DMs between its members, its presentations.
--   · One archive per (Baku calendar day, scope): closing the same day again appends to the same archive.
--     archived_messages keep the message id as key (insert ... on conflict do nothing) and presentation snapshots are unique per
--     event, so nothing is archived twice.
--   · Presentations archived: not yet archived, not draft, not live, and either finished or scheduled on/before that day.
--     Open/drawn ones are frozen and finished first (their state is kept). Each snapshot stores the event, every team with its
--     members, speaking order, files (storage path, name, size, uploader, hidden flag), the final version, topic picks and
--     announcements. Files stay in the private team-files bucket; nothing is deleted from storage.
--   · Team chats of archived presentations (p:<event>:<group>) are archived with the other chats.
--   · Live presentations are skipped (reported back), never cut off.
--   · Runs as one statement inside one transaction: any error rolls back everything (no partial archive).
-- admin_close_day(lbl, dissolve) keeps its signature and calls close_day(..., null).
-- Rollback: supabase/rollback/v12_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regprocedure('public.close_day(text,boolean,text)') is not null then raise exception 'pre-flight: item8 already applied'; end if;
  if to_regclass('public.pres_topics') is null then raise exception 'pre-flight: item9 (pres_topics) must be applied first'; end if;
end $$;

alter table public.archives add column if not exists day date;
alter table public.archives add column if not exists class_tag text references public.classes (tag) on update cascade;
create unique index if not exists archives_day_scope on public.archives (day, coalesce(class_tag, '*')) where day is not null;

alter table public.pres_events add column if not exists archived_at timestamptz;
alter table public.pres_events add column if not exists archive_id bigint references public.archives (id);

create table public.archived_presentations (
  id bigint generated always as identity primary key,
  archive_id bigint not null references public.archives (id) on delete cascade,
  event_id bigint not null unique references public.pres_events (id),
  class_tag text not null,
  title text not null,
  day date not null,
  snapshot jsonb not null,
  archived_by uuid,
  archived_at timestamptz not null default now()
);
create index archived_presentations_archive on public.archived_presentations (archive_id);

-- who may read an archive: admins for every archive, teachers/presentation staff for archives of their class
create or replace function public._arch_staff(a bigint) returns boolean
 language sql stable security definer set search_path = pg_catalog, public as $$
  select auth.uid() is not null and (public._is_admin() or exists (select 1 from public.archives x where x.id = a and x.class_tag is not null
     and (public._is_teacher_of(x.class_tag) or public._cperm(x.class_tag, 'presentations')))) $$;

alter table public.archived_presentations enable row level security;
create policy r on public.archived_presentations for select to authenticated using (public._arch_staff(archive_id));
create policy r_staff on public.archived_messages for select to authenticated using (public._arch_staff(archive_id));
revoke all on public.archived_presentations from public, anon, authenticated;
grant select on public.archived_presentations to authenticated;

create or replace function public._pres_snapshot(e bigint) returns jsonb
 language sql stable security definer set search_path = pg_catalog, public as $$
  select jsonb_build_object(
    'event', (select to_jsonb(ev) - 'archive_id' from public.pres_events ev where ev.id = e),
    'topics', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title) order by t.position) from public.pres_topics t where t.event_id = e and t.removed_at is null), '[]'),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('body', a.body, 'at', a.created_at) order by a.id) from public.pres_announcements a where a.event_id = e), '[]'),
    'teams', coalesce((select jsonb_agg(jsonb_build_object(
        'group_id', tm.group_id, 'group_name', tm.group_name, 'removed', tm.removed_at is not null,
        'speak_state', tm.speak_state, 'final_state', tm.final_state,
        'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.user_name, 'participant', r.participant, 'left', r.left_at is not null) order by r.user_name)
                    from public.pres_roster r where r.event_id = e and r.group_id = tm.group_id), '[]'),
        'order', coalesce((select jsonb_agg(jsonb_build_object('pos', f.position, 'name', f.user_name) order by f.position) from public.pres_speakers_final f where f.event_id = e and f.group_id = tm.group_id), '[]'),
        'final', (select jsonb_build_object('file_id', s.file_id, 'version', s.version, 'state', s.state, 'name', fl.name, 'path', fl.path)
                    from public.pres_submissions s join public.pres_files fl on fl.id = s.file_id
                   where s.event_id = e and s.group_id = tm.group_id and s.state in ('submitted','approved') limit 1),
        'files', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'name', fl.name, 'path', fl.path, 'mime', fl.mime, 'size', fl.size,
                    'uploader', fl.uploader_name, 'at', fl.created_at, 'hidden', fl.hidden_at is not null) order by fl.id)
                    from public.pres_files fl where fl.event_id = e and fl.group_id = tm.group_id), '[]'),
        'topics', coalesce((select jsonb_agg(jsonb_build_object('name', p.user_name, 'topic', t.title) order by p.user_name)
                    from public.pres_topic_picks p join public.pres_topics t on t.id = p.topic_id where p.event_id = e and p.group_id = tm.group_id), '[]')
      ) order by tm.group_name) from public.pres_event_teams tm where tm.event_id = e), '[]')) $$;

create or replace function public.close_day(lbl text, dissolve boolean default false, cls text default null) returns jsonb
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); d date := (now() at time zone 'Asia/Baku')::date; a bigint; ctag text := nullif(lower(trim(coalesce(cls, ''))), '');
        evs bigint[]; live int; nm int; np int; e bigint;
begin
  if ctag is null then perform public._req_admin();
  else
    if not exists (select 1 from public.classes c where c.tag = ctag) then raise exception 'Class not found'; end if;
    if not public._is_teacher_of(ctag) then raise exception 'You do not have permission for this action'; end if;
  end if;
  -- serialise concurrent closes of the same scope
  perform pg_advisory_xact_lock(hashtext('adiak.close_day:' || coalesce(ctag, '*')));
  select id into a from public.archives where day = d and coalesce(class_tag, '*') = coalesce(ctag, '*');
  if a is null then
    insert into public.archives (label, created_by, day, class_tag)
    values (left(coalesce(nullif(trim(lbl), ''), 'Archive ' || to_char(d, 'YYYY-MM-DD') || coalesce(' · ' || ctag, '')), 120), u, d, ctag) returning id into a;
  end if;

  -- presentations of the day
  select array_agg(ev.id order by ev.id) into evs from public.pres_events ev
   where ev.archived_at is null and ev.status not in ('draft','live') and (ctag is null or ev.class_tag = ctag)
     and (ev.status = 'done' or (ev.starts_at is not null and (ev.starts_at at time zone 'Asia/Baku')::date <= d));
  select count(*) into live from public.pres_events ev where ev.archived_at is null and ev.status = 'live' and (ctag is null or ev.class_tag = ctag);
  foreach e in array coalesce(evs, '{}') loop
    perform public._pres_freeze(e);
    update public.pres_events set status = 'done', updated_at = now() where id = e and status <> 'done';
    insert into public.archived_presentations (archive_id, event_id, class_tag, title, day, snapshot, archived_by)
    select a, ev.id, ev.class_tag, ev.title, d, public._pres_snapshot(ev.id), u from public.pres_events ev where ev.id = e
    on conflict (event_id) do nothing;
    update public.pres_events set archived_at = now(), archive_id = a where id = e;
  end loop;
  np := coalesce(array_length(evs, 1), 0);

  -- chats in scope (+ team chats of the presentations archived now)
  create temp table if not exists pg_temp.close_day_msgs (id bigint primary key) on commit drop;
  delete from pg_temp.close_day_msgs;
  insert into pg_temp.close_day_msgs (id)
  select m.id from public.messages m
   where (m.channel !~ '^p:' and (ctag is null
           or (m.channel = 'all' and m.class_tag = ctag)
           or (m.channel ~ '^g:[0-9]+$' and exists (select 1 from public.groups g where g.id = split_part(m.channel, ':', 2)::bigint and g.class_tag = ctag))
           or (m.channel ~ '^d:' and (select count(*) from public.profiles p where p.class_tag = ctag
                 and p.id::text in (split_part(m.channel, ':', 2), split_part(m.channel, ':', 3))) = 2)))
      or (m.channel ~ '^p:[0-9]{1,12}:[0-9]{1,12}$' and split_part(m.channel, ':', 2)::bigint = any (coalesce(evs, '{}')));
  insert into public.archived_messages (id, archive_id, channel, channel_label, sender, body, file_path, file_name, file_type, file_size, created_at, participants)
  select m.id, a, m.channel,
    case when m.channel = 'all' then 'Everyone'
         when m.channel like 'g:%' then coalesce((select name from public.groups where id = split_part(m.channel, ':', 2)::bigint), 'Group')
         when m.channel like 'p:%' then coalesce((select ev.title || ' · ' || t.group_name from public.pres_events ev join public.pres_event_teams t on t.event_id = ev.id
                    where ev.id = split_part(m.channel, ':', 2)::bigint and t.group_id = split_part(m.channel, ':', 3)::bigint), 'Presentation team')
         else coalesce((select string_agg(name, ' & ' order by name) from public.profiles
                    where id::text in (split_part(m.channel, ':', 2), split_part(m.channel, ':', 3))), 'Chat') end,
    m.sender, m.body, m.file_path, m.file_name, m.file_type, m.file_size, m.created_at,
    case when m.channel = 'all' then null
         when m.channel like 'g:%' then coalesce((select array_agg(p.id) from public.profiles p where p.group_id = split_part(m.channel, ':', 2)::bigint), '{}')
         when m.channel like 'p:%' then coalesce((select array_agg(distinct r.user_id) from public.pres_roster r
                    where r.event_id = split_part(m.channel, ':', 2)::bigint and r.group_id = split_part(m.channel, ':', 3)::bigint), '{}')
         else array[split_part(m.channel, ':', 2)::uuid, split_part(m.channel, ':', 3)::uuid] end
  from public.messages m join pg_temp.close_day_msgs x on x.id = m.id
  on conflict (id) do nothing;
  get diagnostics nm = row_count;
  delete from public.message_reads r where exists (select 1 from public.messages m join pg_temp.close_day_msgs x on x.id = m.id where m.channel = r.channel);
  delete from public.messages m using pg_temp.close_day_msgs x where x.id = m.id;

  if dissolve then delete from public.groups g where ctag is null or g.class_tag = ctag; end if;
  return jsonb_build_object('archive_id', a, 'day', d, 'messages', nm, 'presentations', np, 'skipped_live', live);
end $$;

create or replace function public.admin_close_day(lbl text, dissolve boolean) returns bigint
 language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  return (public.close_day(lbl, dissolve, null) ->> 'archive_id')::bigint;
end $$;

revoke all on function public._pres_snapshot(bigint) from public, anon, authenticated, service_role;
revoke all on function public._arch_staff(bigint), public.close_day(text, boolean, text) from public, anon, authenticated, service_role;
grant execute on function public._arch_staff(bigint), public.close_day(text, boolean, text) to authenticated;
