-- ADIAK 1.2 rollback (non-destructive). Generated from the function bodies of production state 20261109101200.
-- Restores every function that the 1.1 migrations replaced, removes the 1.1 triggers and revokes the 1.1 RPCs from clients.
-- New tables/columns and their data stay (archived presentations, topics, read receipts, presence); nothing is deleted.
-- Choices accepted meanwhile stay accepted. Run as one transaction: psql -1 -f supabase/rollback/v12_restore.sql
drop trigger if exists tg_pres_team_settle on public.pres_event_teams;
drop trigger if exists tg_pres_roster_settle on public.pres_roster;
CREATE OR REPLACE FUNCTION public.pres_pick(e bigint, pos integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e); t public.pres_event_teams; n int; old int; holder uuid;
begin
  perform public._rate('pick', 40, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  t := public._pres_team_lock(e, g);
  if t.speak_state <> 'open' then raise exception 'The speaking order is locked (%).', t.speak_state; end if;
  n := public._pres_active_n(e, g);
  if pos is null or pos < 1 or pos > n then raise exception 'Choose a position from 1 to %', n; end if;
  select user_id into holder from public.pres_speakers where event_id = e and group_id = g and position = pos;
  if holder is not null and holder <> u then raise exception 'That position is already taken'; end if;
  select position into old from public.pres_speakers where event_id = e and group_id = g and user_id = u;
  if old = pos then return; end if;
  if old is null then insert into public.pres_speakers (event_id, group_id, user_id, position) values (e, g, u, pos);
  else update public.pres_speakers set position = pos, chosen_at = now() where event_id = e and group_id = g and user_id = u; end if;
  perform public._pres_order_log(e, g, u, case when old is null then 'pick' else 'change' end, old, pos);
end $function$
;
CREATE OR REPLACE FUNCTION public.pres_unpick(e bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e); t public.pres_event_teams; old int;
begin
  perform public._rate('pick', 40, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  t := public._pres_team_lock(e, g);
  if t.speak_state <> 'open' then raise exception 'The speaking order is locked (%).', t.speak_state; end if;
  delete from public.pres_speakers where event_id = e and group_id = g and user_id = u returning position into old;
  if old is not null then perform public._pres_order_log(e, g, u, 'unpick', old, null); end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.pres_submit_order(e bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare u uuid := public._me_ok(); g bigint := public._pres_my_group(e); t public.pres_event_teams; ev public.pres_events; host uuid;
begin
  perform public._rate('order', 10, 60);
  if g is null then raise exception 'You are not in a team for this presentation'; end if;
  t := public._pres_team_lock(e, g);
  if t.speak_state <> 'open' then raise exception 'The speaking order was already submitted'; end if;
  if not public._pres_order_complete(e, g) then raise exception 'Every member must choose a different position first'; end if;
  update public.pres_event_teams set speak_state = 'submitted', speak_by = u, speak_at = now() where event_id = e and group_id = g;
  perform public._pres_order_log(e, g, u, 'submit', null, null);
  select * into ev from public.pres_events where id = e; select host_id into host from public.groups where id = g;
  perform public._notify(array_append(public._pres_staff_ids(ev.class_tag), host), 'pres.order_submitted',
    jsonb_build_object('title', ev.title, 'team', t.group_name), public._pres_tgt(e, g, 'order'), 'osub:' || e || ':' || g || ':' || extract(epoch from now())::bigint);
end $function$
;
CREATE OR REPLACE FUNCTION public.pres_submit_final(fid bigint, expected_active bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare u uuid := public._me_ok(); f public.pres_files; t public.pres_event_teams; act public.pres_submissions; v int; nid bigint; ev public.pres_events;
begin
  perform public._rate('final', 10, 600);
  select * into f from public.pres_files where id = fid;
  if not found or f.hidden_at is not null then raise exception 'File not found'; end if;
  if not public._pres_member(f.event_id, f.group_id) then raise exception 'Only members of this team can submit its final version'; end if;
  t := public._pres_team_lock(f.event_id, f.group_id);
  select * into act from public.pres_submissions where event_id = f.event_id and group_id = f.group_id and state in ('submitted','approved') for update;
  if act.id is distinct from expected_active then raise exception 'The final version changed meanwhile. Reload and try again.'; end if;
  if act.state = 'approved' then raise exception 'An approved final already exists. Only staff can return it for corrections.'; end if;
  if act.id is not null then update public.pres_submissions set state = 'superseded' where id = act.id; end if;
  select coalesce(max(version), 0) + 1 into v from public.pres_submissions where event_id = f.event_id and group_id = f.group_id;
  insert into public.pres_submissions (event_id, group_id, file_id, version, submitted_by) values (f.event_id, f.group_id, fid, v, u) returning id into nid;
  update public.pres_event_teams set final_state = 'submitted' where event_id = f.event_id and group_id = f.group_id;
  select * into ev from public.pres_events where id = f.event_id;
  perform public._notify(public._pres_staff_ids(ev.class_tag), 'pres.final_submitted',
    jsonb_build_object('title', ev.title, 'team', t.group_name, 'v', v, 'file', f.name), public._pres_tgt(f.event_id, f.group_id, 'files', nid), 'fsub:' || nid);
  return nid;
end $function$
;
CREATE OR REPLACE FUNCTION public._tg_pres_sub_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  if old.state = new.state then return new; end if;
  if not ((old.state = 'submitted' and new.state in ('approved','returned','superseded'))
       or (old.state = 'approved' and new.state = 'returned')) then
    raise exception 'Invalid submission transition % -> %', old.state, new.state;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public._only_students_in_groups()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
 if new.group_id is not null and (new.role<>'student' or new.is_admin) then raise exception 'Only students can be placed in groups'; end if;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.create_group(nm text, cap integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p profiles; gid bigint; mx int;
begin
 perform public._rate('group', 5, 600);  -- ADIAK 1.0 rate limit
 select * into p from profiles where id=auth.uid(); if not found then raise exception 'Not signed in'; end if;
 if p.is_admin or p.group_id is not null then raise exception 'Only idle students can create a group'; end if;
 if p.class_tag is null then raise exception 'Enter your class group number first'; end if;
 if cap is null or cap not between 1 and 10 then raise exception 'Size must be 1 to 10'; end if;
 if nm is null or char_length(trim(nm)) not between 1 and 30 then raise exception 'Group name must be 1 to 30 characters'; end if;
 select value::int into mx from app_settings where key='max_groups';
 if (select count(*) from groups where class_tag=p.class_tag)>=coalesce(mx,6) then raise exception 'The group limit (%) is reached', coalesce(mx,6); end if;
 insert into groups(name,capacity,host_id,class_tag) values(trim(nm),cap,p.id,p.class_tag) returning id into gid;
 update profiles set group_id=gid where id=p.id;
 delete from requests where user_id=p.id;
 perform _say('g:'||gid,p.name||' created the group.');
end $function$
;
CREATE OR REPLACE FUNCTION public.request_join(g bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p profiles; n int; cap int;
begin
 perform public._rate('join', 10, 600);  -- ADIAK 1.0 rate limit
 select * into p from profiles where id=auth.uid(); if not found then raise exception 'Not signed in'; end if;
 if p.is_admin then raise exception 'The host account cannot join groups'; end if;
 if p.group_id is not null then raise exception 'Leave your current group first'; end if;
 if p.class_tag is null then raise exception 'Enter your class group number first'; end if;
 select capacity into cap from groups where id=g; if not found then raise exception 'Group not found'; end if;
 if (select class_tag from groups where id=g) is distinct from p.class_tag then raise exception 'This team belongs to another class group'; end if;
 select count(*) into n from profiles where group_id=g;
 if n>=cap then raise exception 'This group is full'; end if;
 if n=0 then perform _accept(p.id,g); return; end if;
 if not exists(select 1 from requests where user_id=p.id and group_id=g) then
  insert into requests(user_id,group_id) values(p.id,g);
  perform _say('g:'||g,p.name||' wants to join. A member can put the request to a vote.');
 end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.send_invite(g bigint, u uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p profiles; t profiles; n int; cap int;
begin
 perform public._rate('invite', 20, 600);  -- ADIAK 1.0 rate limit
 select * into p from profiles where id=auth.uid();
 select * into t from profiles where id=u;
 if not found or t.is_admin then raise exception 'Person not found'; end if;
 if not exists(select 1 from groups where id=g and host_id=p.id) then raise exception 'Only the group host can invite'; end if;
 if t.group_id is not null then raise exception 'That person is already in a group'; end if;
 if t.class_tag is distinct from (select class_tag from groups where id=g) then raise exception 'That person is in another class group'; end if;
 select capacity into cap from groups where id=g;
 select count(*) into n from profiles where group_id=g;
 if n>=cap then raise exception 'Your group is full'; end if;
 if exists(select 1 from requests where user_id=u and group_id=g) then
  perform _accept(u,g); return;
 end if;
 insert into invites(group_id,user_id,invited_by) values(g,u,p.id) on conflict do nothing;
 perform _say('g:'||g,p.name||' invited '||t.name||'.');
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_move_member(u uuid, g bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare old bigint; nm text; cap int; n int;
begin perform public._req_c('groups',public._gtag(g));
 select group_id,name into old,nm from profiles where id=u;
 select capacity into cap from groups where id=g; if not found then raise exception 'Group not found'; end if;
 select count(*) into n from profiles where group_id=g;
 if n>=cap and old is distinct from g then raise exception 'That group is full'; end if;
 update profiles set group_id=g where id=u; delete from requests where user_id=u; delete from invites where user_id=u; delete from kicks where target_id=u;
 if old is not null and old<>g then perform _fix_host(old); end if;
 perform _fix_host(g); perform _say('g:'||g,nm||' was added to this group.');
end $function$
;
CREATE OR REPLACE FUNCTION public._chan_ok(ch text, u uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g bigint; a uuid; b uuid;
begin
 if ch='all' then return true; end if;
 select group_id into g from profiles where id=u;
 if g is not null and ch='g:'||g then return true; end if;
 if ch like 'd:%' then a:=split_part(ch,':',2)::uuid; b:=split_part(ch,':',3)::uuid;
  return a<>b and u in (a,b) and public._can_see_user(case when a=u then b else a end,u); end if;
 -- ADIAK 1.0: presentation event chat p:<event>:<group>
 if ch ~ '^p:[0-9]{1,12}:[0-9]{1,12}$' then
  return public._pres_can_post(split_part(ch,':',2)::bigint, split_part(ch,':',3)::bigint, u); end if;
 return false;
exception when others then return false;
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_close_day(lbl text, dissolve boolean)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a bigint;
begin perform _req_admin();
 insert into archives(label,created_by) values(coalesce(nullif(trim(lbl),''),'Archive '||to_char(now(),'YYYY-MM-DD')),auth.uid()) returning id into a;
 insert into archived_messages(id,archive_id,channel,channel_label,sender,body,file_path,file_name,file_type,file_size,created_at,participants)
  select m.id,a,m.channel,
   case when m.channel='all' then 'Everyone'
        when m.channel like 'g:%' then coalesce((select name from groups where id=split_part(m.channel,':',2)::bigint),'Group')
        else coalesce((select string_agg(name,' & ' order by name) from profiles where id in (split_part(m.channel,':',2)::uuid,split_part(m.channel,':',3)::uuid)),'Chat') end,
   m.sender,m.body,m.file_path,m.file_name,m.file_type,m.file_size,m.created_at,
   case when m.channel='all' then null
        when m.channel like 'g:%' then coalesce((select array_agg(p.id) from profiles p where p.group_id=split_part(m.channel,':',2)::bigint),'{}')
        else array[split_part(m.channel,':',2)::uuid,split_part(m.channel,':',3)::uuid] end
  from messages m where m.channel not like 'p:%';
 delete from messages where channel not like 'p:%';
 if dissolve then delete from groups; end if;
 return a;
end $function$
;
CREATE OR REPLACE FUNCTION public._notify(users uuid[], k text, p jsonb, tgt jsonb, dedupe text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare n int := 0;
begin
  begin
    insert into public.notifications (user_id, kind, params, target, dedupe_key)
      select distinct u, k, coalesce(p, '{}'), coalesce(tgt, '{}'), dedupe
      from unnest(users) u
      where u is not null and exists (select 1 from public.profiles pr where pr.id = u)
    on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
    get diagnostics n = row_count;
  exception when others then
    begin insert into public.notify_errors (kind, users, err) values (k, users, left(sqlerrm, 500));
    exception when others then null; end;
    n := 0;
  end;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public._tg_note_outbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  begin
    insert into public.push_outbox (notification_id, device_id)
      select new.id, d.id from public.push_devices d where d.user_id = new.user_id and d.disabled_at is null
    on conflict do nothing;
    if found then perform public._push_kick(); end if;
  exception when others then
    begin insert into public.notify_errors (kind, users, err) values ('outbox:' || new.kind, array[new.user_id], left(sqlerrm, 500));
    exception when others then null; end;
  end;
  return null;
end $function$
;
do $$ declare f text; begin
  foreach f in array array['admin_create_group(text,text,integer)','admin_group_set_teacher(bigint,uuid)','mark_read(text,bigint)','presence_ping(boolean)',
    'presence_bye()','change_my_password(text,text)','pres_topics_add(bigint,text[],text)','pres_topic_edit(bigint,text)','pres_topic_remove(bigint)',
    'pres_topic_limit(bigint,integer)','pres_topic_pick(bigint)','pres_topic_unpick(bigint)','pres_topic_release(bigint,uuid)','close_day(text,boolean,text)'] loop
    execute format('revoke execute on function public.%s from authenticated', f);
  end loop;
end $$;
