-- ADIAK 1.2 / items 2 + 4.
-- Item 4: the system role (admin flag / 'admin' permission) and the group role are separate. Group participation depends only on
--   profiles.role = 'student' (+ a class). An admin who is a student can create, join, be invited to and be moved into groups
--   like any student; admin powers are unchanged. Teachers still never become group members.
-- Item 2: admins (or staff with the 'groups' permission for that class) create EMPTY groups (admin_create_group) and may
--   assign a supervising teacher of the class (admin_group_set_teacher). Students are added later with admin_move_member.
--   The supervising teacher can read and write the group chat. Deleting a group keeps working through admin_delete_group.
-- Rollback: supabase/rollback/v12_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regprocedure('public.admin_create_group(text,text,integer)') is not null then raise exception 'pre-flight: item2/4 already applied'; end if;
  if to_regprocedure('public._only_students_in_groups()') is null then raise exception 'pre-flight: baseline missing'; end if;
end $$;

-- ===== item 4: participation = student role =====
create or replace function public._only_students_in_groups() returns trigger
 language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.group_id is not null and new.role <> 'student' then raise exception 'Only students can be placed in groups'; end if;
  return new;
end $$;

create or replace function public.create_group(nm text, cap integer) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare p public.profiles; gid bigint; mx int;
begin
  perform public._rate('group', 5, 600);
  select * into p from public.profiles where id = auth.uid(); if not found then raise exception 'Not signed in'; end if;
  if p.role <> 'student' or p.group_id is not null then raise exception 'Only idle students can create a group'; end if;
  if p.class_tag is null then raise exception 'Enter your class group number first'; end if;
  if cap is null or cap not between 1 and 10 then raise exception 'Size must be 1 to 10'; end if;
  if nm is null or char_length(trim(nm)) not between 1 and 30 then raise exception 'Group name must be 1 to 30 characters'; end if;
  select value::int into mx from public.app_settings where key = 'max_groups';
  if (select count(*) from public.groups where class_tag = p.class_tag) >= coalesce(mx, 6) then raise exception 'The group limit (%) is reached', coalesce(mx, 6); end if;
  insert into public.groups (name, capacity, host_id, class_tag) values (trim(nm), cap, p.id, p.class_tag) returning id into gid;
  update public.profiles set group_id = gid where id = p.id;
  delete from public.requests where user_id = p.id;
  perform public._say('g:' || gid, p.name || ' created the group.');
end $$;

create or replace function public.request_join(g bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare p public.profiles; n int; cap int;
begin
  perform public._rate('join', 10, 600);
  select * into p from public.profiles where id = auth.uid(); if not found then raise exception 'Not signed in'; end if;
  if p.role <> 'student' then raise exception 'Teachers do not join groups'; end if;
  if p.group_id is not null then raise exception 'Leave your current group first'; end if;
  if p.class_tag is null then raise exception 'Enter your class group number first'; end if;
  select capacity into cap from public.groups where id = g; if not found then raise exception 'Group not found'; end if;
  if (select class_tag from public.groups where id = g) is distinct from p.class_tag then raise exception 'This team belongs to another class group'; end if;
  select count(*) into n from public.profiles where group_id = g;
  if n >= cap then raise exception 'This group is full'; end if;
  if n = 0 then perform public._accept(p.id, g); return; end if;
  if not exists (select 1 from public.requests where user_id = p.id and group_id = g) then
    insert into public.requests (user_id, group_id) values (p.id, g);
    perform public._say('g:' || g, p.name || ' wants to join. A member can put the request to a vote.');
  end if;
end $$;

create or replace function public.send_invite(g bigint, u uuid) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare p public.profiles; t public.profiles; n int; cap int;
begin
  perform public._rate('invite', 20, 600);
  select * into p from public.profiles where id = auth.uid();
  select * into t from public.profiles where id = u;
  if not found or t.role <> 'student' then raise exception 'Person not found'; end if;
  if not exists (select 1 from public.groups where id = g and host_id = p.id) then raise exception 'Only the group host can invite'; end if;
  if t.group_id is not null then raise exception 'That person is already in a group'; end if;
  if t.class_tag is distinct from (select class_tag from public.groups where id = g) then raise exception 'That person is in another class group'; end if;
  select capacity into cap from public.groups where id = g;
  select count(*) into n from public.profiles where group_id = g;
  if n >= cap then raise exception 'Your group is full'; end if;
  if exists (select 1 from public.requests where user_id = u and group_id = g) then perform public._accept(u, g); return; end if;
  insert into public.invites (group_id, user_id, invited_by) values (g, u, p.id) on conflict do nothing;
  perform public._say('g:' || g, p.name || ' invited ' || t.name || '.');
end $$;

-- moving someone into a group: clear message for teachers (instead of the trigger error), class check before the trigger
create or replace function public.admin_move_member(u uuid, g bigint) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare old bigint; nm text; cap int; n int; rl text; ut text; gt text;
begin
  perform public._req_c('groups', public._gtag(g));
  select group_id, name, role, class_tag into old, nm, rl, ut from public.profiles where id = u;
  if not found then raise exception 'Person not found'; end if;
  if rl <> 'student' then raise exception 'Only students can be placed in groups'; end if;
  select capacity, class_tag into cap, gt from public.groups where id = g; if not found then raise exception 'Group not found'; end if;
  if ut is distinct from gt then raise exception 'This team belongs to another class group'; end if;
  select count(*) into n from public.profiles where group_id = g;
  if n >= cap and old is distinct from g then raise exception 'That group is full'; end if;
  update public.profiles set group_id = g where id = u;
  delete from public.requests where user_id = u; delete from public.invites where user_id = u; delete from public.kicks where target_id = u;
  if old is not null and old <> g then perform public._fix_host(old); end if;
  perform public._fix_host(g); perform public._say('g:' || g, nm || ' was added to this group.');
end $$;

-- ===== item 2: empty groups + supervising teacher =====
alter table public.groups add column if not exists teacher_id uuid references public.profiles (id) on delete set null;
alter table public.groups add column if not exists created_by uuid references public.profiles (id) on delete set null;
alter table public.groups add column if not exists created_at timestamptz default now();

create or replace function public.admin_create_group(cls text, nm text, cap integer) returns bigint
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); gid bigint; mx int; ctag text := lower(trim(coalesce(cls, '')));
begin
  perform public._rate('admin_group', 30, 600);
  if not exists (select 1 from public.classes c where c.tag = ctag) then raise exception 'Class not found'; end if;
  perform public._req_c('groups', ctag);
  if nm is null or char_length(trim(nm)) not between 1 and 30 then raise exception 'Group name must be 1 to 30 characters'; end if;
  if cap is null or cap not between 1 and 10 then raise exception 'Size must be 1 to 10'; end if;
  if exists (select 1 from public.groups g where g.class_tag = ctag and lower(g.name) = lower(trim(nm))) then raise exception 'A group with this name already exists in this class'; end if;
  select value::int into mx from public.app_settings where key = 'max_groups';
  if (select count(*) from public.groups g where g.class_tag = ctag) >= coalesce(mx, 6) then raise exception 'The group limit (%) is reached', coalesce(mx, 6); end if;
  insert into public.groups (name, capacity, host_id, class_tag, created_by) values (trim(nm), cap, null, ctag, u) returning id into gid;
  perform public._say('g:' || gid, 'The group was created by staff. Members are added by the class staff.');
  return gid;
end $$;

create or replace function public.admin_group_set_teacher(g bigint, t uuid) returns void
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare tag text := public._gtag(g); gname text; old uuid;
begin
  perform public._me_ok();
  if tag is null then raise exception 'Group not found'; end if;
  perform public._req_c('groups', tag);
  select name, teacher_id into gname, old from public.groups where id = g;
  if t is not null and not exists (select 1 from public.class_staff s where s.user_id = t and s.class_tag = tag and s.role = 'teacher') then
    raise exception 'Choose a teacher of this class'; end if;
  if old is not distinct from t then return; end if;
  update public.groups set teacher_id = t where id = g;
  if t is not null then
    perform public._notify(array[t], 'group.teacher', jsonb_build_object('group', gname), jsonb_build_object('k', 'group', 'id', g), 'gteach:' || g || ':' || t);
    perform public._say('g:' || g, coalesce((select name from public.profiles where id = t), 'A teacher') || ' supervises this group.');
  end if;
end $$;

-- the supervising teacher may read/write the group chat (everything else in _chan_ok is unchanged)
create or replace function public._chan_ok(ch text, u uuid) returns boolean
 language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare g bigint; a uuid; b uuid;
begin
  if ch = 'all' then return true; end if;
  select group_id into g from public.profiles where id = u;
  if g is not null and ch = 'g:' || g then return true; end if;
  if ch ~ '^g:[0-9]{1,18}$' and exists (select 1 from public.groups gr where gr.id = split_part(ch, ':', 2)::bigint and gr.teacher_id = u) then return true; end if;
  if ch like 'd:%' then a := split_part(ch, ':', 2)::uuid; b := split_part(ch, ':', 3)::uuid;
    return a <> b and u in (a, b) and public._can_see_user(case when a = u then b else a end, u); end if;
  if ch ~ '^p:[0-9]{1,12}:[0-9]{1,12}$' then
    return public._pres_can_post(split_part(ch, ':', 2)::bigint, split_part(ch, ':', 3)::bigint, u); end if;
  return false;
exception when others then return false;
end $$;

revoke all on function public.admin_create_group(text, text, integer), public.admin_group_set_teacher(bigint, uuid) from public, anon, authenticated, service_role;
grant execute on function public.admin_create_group(text, text, integer), public.admin_group_set_teacher(bigint, uuid) to authenticated;
