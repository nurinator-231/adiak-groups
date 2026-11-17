-- ADIAK 1.1 / item 3: students' choices take effect without a teacher's approval.
--   Speaking order: every pick/unpick settles the team's order. When each active member holds a different position 1..n the
--   order is 'approved' at once (no 'submitted' waiting state); otherwise it is 'open'. When a member leaves, their pick is
--   dropped and, if a remaining pick no longer fits the smaller team, the picks are renumbered in their order (a leaver no
--   longer blocks the team).
--   Final presentation: pres_submit_final stores the chosen file as the approved final immediately. Team members may replace it
--   until the event is frozen (the previous one becomes 'superseded'). Staff keep their powers (return, reopen, approve).
--   Existing data: pending orders/finals of events that are not frozen are settled/accepted once. Nothing is deleted except
--   withdrawn speaker picks (kept in pres_speaker_log and pres_audit).
-- Rollback: supabase/rollback/v11_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regprocedure('public.pres_submit_final(bigint,bigint)') is null then raise exception 'pre-flight: M3 (pres_rpcs) must be applied first'; end if;
  if to_regprocedure('public._pres_order_settle(bigint,bigint)') is not null then raise exception 'pre-flight: item3 already applied'; end if;
end $$;

-- settle one team's order: drop picks of non-members, renumber when picks exceed the team size, approve when complete.
create or replace function public._pres_order_settle(e bigint, g bigint) returns text
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pres_event_teams; ev public.pres_events; st text; gap boolean; us uuid[]; cs timestamptz[];
begin
  select * into ev from public.pres_events where id = e;
  if not found or ev.frozen_at is not null or ev.status not in ('draft','open','drawn') then return null; end if;
  select * into t from public.pres_event_teams where event_id = e and group_id = g and removed_at is null for update;
  if not found then return null; end if;
  -- picks of people who are no longer active members (withdrawn or left) are dropped
  delete from public.pres_speakers s where s.event_id = e and s.group_id = g
     and (s.withdrawn or not exists (select 1 from public.pres_roster r where r.event_id = e and r.group_id = g and r.user_id = s.user_id and r.left_at is null));
  -- after someone left, picks above the new team size cannot be valid any more: renumber 1..k keeping the chosen order
  -- (only then; normal gaps while members are still choosing stay). The unique (event,group,position) key is not deferrable: delete + insert.
  select exists (select 1 from public.pres_speakers where event_id = e and group_id = g and position > public._pres_active_n(e, g)) into gap;
  if gap then
    select array_agg(user_id order by position), array_agg(chosen_at order by position) into us, cs
      from public.pres_speakers where event_id = e and group_id = g;
    delete from public.pres_speakers where event_id = e and group_id = g;
    insert into public.pres_speakers (event_id, group_id, user_id, position, chosen_at)
    select e, g, us[i], i, cs[i] from generate_subscripts(us, 1) i;
    perform public._pres_order_log(e, g, null, 'compact', null, null);
  end if;
  st := case when public._pres_order_complete(e, g) then 'approved' else 'open' end;
  if st is distinct from t.speak_state then
    update public.pres_event_teams set speak_state = st, speak_by = auth.uid(), speak_at = now() where event_id = e and group_id = g;
    if st = 'approved' then
      perform public._pres_order_log(e, g, auth.uid(), 'auto_accept', null, null);
      perform public._notify(public._pres_team_ids(e, g), 'pres.order_approved', jsonb_build_object('title', ev.title), public._pres_tgt(e, g, 'order'),
        'oapp:' || e || ':' || g || ':' || extract(epoch from now())::bigint);
    end if;
  end if;
  return st;
end $$;

-- an accepted final may now be replaced by the team: approved -> superseded becomes a valid transition (all others unchanged)
create or replace function public._tg_pres_sub_transition() returns trigger
 language plpgsql set search_path = pg_catalog, public as $$
begin
  if old.state = new.state then return new; end if;
  if not ((old.state = 'submitted' and new.state in ('approved','returned','superseded'))
       or (old.state = 'approved' and new.state in ('returned','superseded'))) then
    raise exception 'Invalid submission transition % -> %', old.state, new.state;
  end if;
  return new;
end $$;

-- legacy states written by the membership trigger ('needs_review' / 'submitted') are settled right away
create or replace function public._tg_pres_team_settle() returns trigger
 language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform public._pres_order_settle(new.event_id, new.group_id);
  return null;
end $$;
create trigger tg_pres_team_settle after update of speak_state on public.pres_event_teams
 for each row when (new.speak_state in ('needs_review','submitted') and new.removed_at is null) execute function public._tg_pres_team_settle();

-- a member joined or left the team of an open event: settle (a newcomer without a pick reopens the order)
create or replace function public._tg_pres_roster_settle() returns trigger
 language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_op = 'UPDATE' and old.left_at is not distinct from new.left_at then return null; end if;
  perform public._pres_order_settle(new.event_id, new.group_id);
  return null;
end $$;
create trigger tg_pres_roster_settle after insert or update of left_at on public.pres_roster
 for each row execute function public._tg_pres_roster_settle();

-- picks are allowed until the event is frozen; each change settles the order (no submit/approve step)
create or replace function public.pres_pick(e bigint, pos int) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e); t public.pres_event_teams; n int; old int; holder uuid;
begin
  perform public._rate('pick', 40, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  t := public._pres_team_lock(e, g);
  n := public._pres_active_n(e, g);
  if pos is null or pos < 1 or pos > n then raise exception 'Choose a position from 1 to %', n; end if;
  select user_id into holder from public.pres_speakers where event_id = e and group_id = g and position = pos and not withdrawn;
  if holder is not null and holder <> u then raise exception 'That position is already taken'; end if;
  select position into old from public.pres_speakers where event_id = e and group_id = g and user_id = u;
  if old is distinct from pos then
    if old is null then insert into public.pres_speakers (event_id, group_id, user_id, position) values (e, g, u, pos);
    else update public.pres_speakers set position = pos, chosen_at = now(), withdrawn = false where event_id = e and group_id = g and user_id = u; end if;
    perform public._pres_order_log(e, g, u, case when old is null then 'pick' else 'change' end, old, pos);
  end if;
  perform public._pres_order_settle(e, g);
end $$;

create or replace function public.pres_unpick(e bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e); t public.pres_event_teams; old int;
begin
  perform public._rate('pick', 40, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  t := public._pres_team_lock(e, g);
  delete from public.pres_speakers where event_id = e and group_id = g and user_id = u returning position into old;
  if old is not null then perform public._pres_order_log(e, g, u, 'unpick', old, null); end if;
  perform public._pres_order_settle(e, g);
end $$;

-- kept for older clients: accepts a complete order immediately
create or replace function public.pres_submit_order(e bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e);
begin
  perform public._rate('order', 10, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  perform public._pres_team_lock(e, g);
  if not public._pres_order_complete(e, g) then raise exception 'Every member must choose a different position first'; end if;
  perform public._pres_order_settle(e, g);
end $$;

-- the chosen final is accepted at once; team members may replace it until the event is frozen
create or replace function public.pres_submit_final(fid bigint, expected_active bigint default null) returns bigint
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); f public.pres_files; t public.pres_event_teams; act public.pres_submissions; v int; nid bigint; ev public.pres_events;
begin
  perform public._rate('final', 10, 600);
  select * into f from public.pres_files where id = fid;
  if not found or f.hidden_at is not null then raise exception 'File not found'; end if;
  if not public._pres_member(f.event_id, f.group_id) then raise exception 'Only members of this team can submit its final version'; end if;
  t := public._pres_team_lock(f.event_id, f.group_id);
  select * into act from public.pres_submissions where event_id = f.event_id and group_id = f.group_id and state in ('submitted','approved') for update;
  if act.id is distinct from expected_active then raise exception 'The final version changed meanwhile. Reload and try again.'; end if;
  if act.file_id = fid then return act.id; end if;
  if act.id is not null then update public.pres_submissions set state = 'superseded' where id = act.id; end if;
  select coalesce(max(version), 0) + 1 into v from public.pres_submissions where event_id = f.event_id and group_id = f.group_id;
  insert into public.pres_submissions (event_id, group_id, file_id, version, state, submitted_by, reviewed_at)
  values (f.event_id, f.group_id, fid, v, 'approved', u, now()) returning id into nid;
  update public.pres_event_teams set final_state = 'approved' where event_id = f.event_id and group_id = f.group_id;
  select * into ev from public.pres_events where id = f.event_id;
  perform public._notify(public._pres_staff_ids(ev.class_tag), 'pres.final_submitted',
    jsonb_build_object('title', ev.title, 'team', t.group_name, 'v', v, 'file', f.name), public._pres_tgt(f.event_id, f.group_id, 'files', nid), 'fsub:' || nid);
  perform public._notify(public._pres_team_ids(f.event_id, f.group_id), 'pres.final_approved', jsonb_build_object('title', ev.title, 'v', v),
    public._pres_tgt(f.event_id, f.group_id, 'files', nid), 'fapp:' || nid);
  return nid;
end $$;

revoke all on function public._pres_order_settle(bigint, bigint), public._tg_pres_team_settle(), public._tg_pres_roster_settle()
  from public, anon, authenticated, service_role;
revoke all on function public.pres_pick(bigint, int), public.pres_unpick(bigint), public.pres_submit_order(bigint), public.pres_submit_final(bigint, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.pres_pick(bigint, int), public.pres_unpick(bigint), public.pres_submit_order(bigint), public.pres_submit_final(bigint, bigint)
  to authenticated;

-- one-time: settle waiting orders and accept pending finals of events that are not frozen
do $$ declare r record; begin
  for r in select t.event_id, t.group_id from public.pres_event_teams t join public.pres_events e on e.id = t.event_id
            where t.removed_at is null and e.frozen_at is null and e.status in ('draft','open','drawn') loop
    perform public._pres_order_settle(r.event_id, r.group_id);
  end loop;
  update public.pres_submissions s set state = 'approved', reviewed_at = coalesce(s.reviewed_at, now())
    from public.pres_events e where e.id = s.event_id and s.state = 'submitted' and e.frozen_at is null;
  update public.pres_event_teams t set final_state = 'approved' from public.pres_events e
   where e.id = t.event_id and t.final_state = 'submitted' and e.frozen_at is null;
end $$;
