-- ADIAK 1.2 item 8: "Günü bitir" archives the day's presentations with the chats, atomically and without duplicates.
select test.mk_event() as e \gset
select test.mk_event() as e2 \gset
select test.mk_event() as e3 \gset
-- e: finished with an uploaded + chosen final; e2: still open, scheduled later; e3: live
insert into storage.objects (bucket_id, name, owner) values ('team-files', 'e' || :e || '/g1/11111111-1111-4111-8111-111111111111.pdf', test.id('s1'));
select test.as(test.id('s1'));
select public.pres_add_file(:e, 'e' || :e || '/g1/11111111-1111-4111-8111-111111111111.pdf', 'Slides.pdf', 'application/pdf', 1000) as f \gset
select public.pres_submit_final(:f, null);
select public.send_message('p:' || :e || ':1', 'team chat of e');
select public.send_message('g:1', 'group chat');
select public.send_message('all', 'class chat');
select test.as(test.id('x1'));
select public.send_message('g:3', 'class 2 chat');
select test.as(test.id('tpres'));
select public.pres_draw(:e, 0); select public.live_start(:e, 0); select public.live_end(:e, 1);
select public.pres_draw(:e3, 0); select public.live_start(:e3, 0);
select test.as(test.id('s1'));
select public.send_message('p:' || :e2 || ':1', 'team chat of e2');
-- permissions
select test.throws($q$select public.close_day('x', false, null)$q$, 'permission|admin', 'student cannot close the day');
select test.as(test.id('tother'));
select test.throws($q$select public.close_day('x', false, 'c1')$q$, 'permission', 'teacher of another class cannot close c1');
select test.throws($q$select public.close_day('x', false, null)$q$, 'permission|admin', 'teacher cannot close the whole platform');
-- teacher closes the day of their class
select test.as(test.id('tpres'));
select public.close_day('Monday', false, 'c1') as r \gset
select test.as_db();
select test.eq((:'r'::jsonb ->> 'presentations')::int, 1, 'one presentation archived (the finished one)');
select test.eq((:'r'::jsonb ->> 'skipped_live')::int, 1, 'live presentation skipped, not cut off');
select test.ok((select archived_at is not null and archive_id is not null from public.pres_events where id = :e), 'finished event marked archived');
select test.ok((select archived_at is null from public.pres_events where id = :e2) and (select archived_at is null from public.pres_events where id = :e3), 'open and live events untouched');
select (:'r'::jsonb ->> 'archive_id')::bigint as a \gset
select test.ok((select day is not null and class_tag = 'c1' from public.archives where id = :a), 'archive bound to the day and the class');
select test.eq((select snapshot #>> '{teams,0,final,name}' from public.archived_presentations where event_id = :e and archive_id = :a), 'Slides.pdf', 'snapshot keeps the final file');
select test.eq((select snapshot #>> '{teams,0,files,0,path}' from public.archived_presentations where event_id = :e), 'e' || :e || '/g1/11111111-1111-4111-8111-111111111111.pdf', 'snapshot keeps the storage path');
select test.eq((select snapshot #>> '{teams,0,group_name}' from public.archived_presentations where event_id = :e), 'Team One', 'snapshot names the team');
select test.ok(exists(select 1 from storage.objects where name like 'e' || :e || '/%'), 'file kept in storage');
select test.eq((select count(*)::int from public.archived_messages where archive_id = :a and channel = 'p:' || :e || ':1'), 1, 'team chat of the archived presentation in the same archive');
select test.eq((select count(*)::int from public.archived_messages where archive_id = :a and channel = 'g:1'), 1, 'group chat archived');
select test.eq((select count(*)::int from public.archived_messages where archive_id = :a and channel = 'all'), 1, 'class chat archived');
select test.eq((select count(*)::int from public.messages where channel = 'p:' || :e2 || ':1'), 1, 'chat of the open presentation kept');
select test.eq((select count(*)::int from public.messages where channel in ('g:1','all')), 0, 'archived chats cleared');
select test.eq((select count(*)::int from public.messages where channel = 'g:3' and body = 'class 2 chat'), 1, 'other class chats untouched by a class close');
-- closing again the same day: same archive, no duplicates
select test.as(test.id('s1'));
select public.send_message('g:1', 'later message');
select test.as(test.id('tpres'));
select public.close_day('again', false, 'c1') as r2 \gset
select test.as_db();
select test.eq((:'r2'::jsonb ->> 'archive_id')::bigint, :a::bigint, 'second close of the day reuses the archive');
select test.eq((select count(*)::int from public.archives where class_tag = 'c1'), 1, 'one archive per day and class');
select test.eq((select count(*)::int from public.archived_presentations where event_id = :e), 1, 'presentation archived once');
select test.eq((select count(*)::int from public.archived_messages where archive_id = :a and channel = 'g:1'), 2, 'new message appended, old not duplicated');
-- reading the archive
select test.as(test.id('tpres'));
select test.eq((select count(*)::int from public.archived_presentations where archive_id = :a), 1, 'class teacher reads the archived presentations');
select test.ok((select count(*) from public.archived_messages where archive_id = :a) >= 3, 'class teacher reads the archived chats');
select test.as(test.id('tother'));
select test.eq((select count(*)::int from public.archived_presentations), 0, 'teacher of another class cannot');
select test.as(test.id('s1'));
select test.eq((select count(*)::int from public.archived_presentations), 0, 'students cannot read presentation archives');
-- admin wrapper keeps working and is atomic
select test.as(test.id('admin'));
select test.ok(public.admin_close_day('All', false) is not null, 'admin_close_day still returns the archive id');
select test.as_db();
select test.ok((select count(*) from public.archives where class_tag is null) = 1, 'platform-wide archive separate from the class archive');
