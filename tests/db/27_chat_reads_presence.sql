-- ADIAK 1.2 item 6: read receipts and last seen.
select test.as(test.id('s1'));
select public.send_message('g:1', 'hello team');
select public.send_message('g:1', 'second');
select test.as_db();
select max(id) as m2 from public.messages where channel = 'g:1' \gset
select test.as(test.id('s2'));
select test.eq(public.mark_read('g:1', :m2), :m2::bigint, 'member marks the group chat as read');
select test.eq(public.mark_read('g:1', :m2 - 1), :m2::bigint, 'older id never moves the receipt back');
select test.eq(public.mark_read('g:1', :m2 + 1000), :m2::bigint, 'receipt capped at the newest real message');
select test.eq(public.mark_read('all', :m2), null::bigint, 'no receipts on the class-wide chat');
select test.throws(format('select public.mark_read(''g:2'', %s)', :m2), 'cannot read', 'cannot mark a chat you cannot access');
select test.as(test.id('s1'));
select test.eq((select last_read_id from public.message_reads where channel = 'g:1' and user_id = test.id('s2')), :m2::bigint, 'sender sees who read it');
select test.as(test.id('s4'));
select test.eq((select count(*)::int from public.message_reads where channel = 'g:1'), 0, 'other team cannot see the receipts');
select test.throws($q$insert into public.message_reads values ('g:2', 'b0000000-0000-4000-8000-000000000004', 1, now())$q$, 'permission', 'no direct writes');
-- DMs
select test.as(test.id('s1'));
select public.send_message('d:' || least(test.id('s1'), test.id('s2')) || ':' || greatest(test.id('s1'), test.id('s2')), 'dm');
select test.as_db();
select max(id) as dm from public.messages where channel like 'd:%' \gset
select test.as(test.id('s2'));
select test.lives(format($q$select public.mark_read('d:%s:%s', %s)$q$, least(test.id('s1'), test.id('s2')), greatest(test.id('s1'), test.id('s2')), :dm), 'DM read receipt');
select test.as(test.id('s3'));
select test.eq((select count(*)::int from public.message_reads where channel like 'd:%'), 0, 'third person cannot see DM receipts');
-- presence
select test.as(test.id('s1'));
select test.ok(public.presence_ping(true) is not null, 'ping stores last seen');
select test.lives('select public.presence_ping(false)', 'second ping within 30 s is throttled (no error)');
select test.lives('select public.presence_bye()', 'bye stores an exact last seen');
select test.as(test.id('s2'));
select test.eq((select count(*)::int from public.user_presence where user_id = test.id('s1')), 1, 'classmate sees last seen');
select test.as(test.id('x1'));
select test.eq((select count(*)::int from public.user_presence where user_id = test.id('s1')), 0, 'other class cannot see it');
select test.as_anon();
select test.throws('select public.presence_ping(true)', 'permission', 'anon cannot ping');
