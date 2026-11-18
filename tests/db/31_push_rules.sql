-- ADIAK 1.2 item 1: push rules (no self-notification, no double push for mentions, token handling unchanged).
select test.as(test.id('s1'));
select public.save_fcm('tok-s1-aaaaaaaaaaaaaaaaaaaaaaaa', 'az');
select test.as(test.id('s2'));
select public.save_fcm('tok-s2-aaaaaaaaaaaaaaaaaaaaaaaa', 'az');
-- _notify called inside an RPC by s1: the caller is skipped
select test.as(test.id('s1'));
select set_config('request.jwt.claims', json_build_object('sub', test.id('s1'), 'role', 'authenticated')::text, true);
reset role;
select test.eq(public._notify(array[test.id('s1'), test.id('s2')], 'points.add', '{}', '{}', 'self-1'), 1, 'triggering user skipped, other user notified');
select test.as_db();
select test.ok(not exists(select 1 from public.notifications where dedupe_key = 'self-1' and user_id = test.id('s1')), 'no notification for the actor');
select test.eq(public._notify(array[test.id('s1')], 'points.add', '{}', '{}', 'cron-1'), 1, 'cron/service context (no caller) unchanged');
-- message push goes to the other member's device only
select test.as(test.id('s1'));
select public.send_message('g:1', 'hello');
select test.as_db();
select max(id) as m from public.messages where channel = 'g:1' \gset
select test.eq((select count(*)::int from public.push_outbox o join public.push_devices d on d.id = o.device_id where o.message_id = :m and d.user_id = test.id('s1')), 0, 'sender gets no push');
select test.eq((select count(*)::int from public.push_outbox o join public.push_devices d on d.id = o.device_id where o.message_id = :m and d.user_id = test.id('s2')), 1, 'member gets exactly one push');
-- mention in the class chat: one push per device, not two
update public.profiles set name = 'Student Two' where id = test.id('s2');
select test.as(test.id('s1'));
select public.send_message('all', 'hi @Student');
select test.as_db();
select max(id) as m2 from public.messages where channel = 'all' \gset
select test.ok(exists(select 1 from public.notifications where kind = 'chat.mention' and user_id = test.id('s2')), 'mention notification kept (in-app)');
select test.eq((select count(*)::int from public.push_outbox o join public.push_devices d on d.id = o.device_id
   where d.user_id = test.id('s2') and (o.message_id = :m2 or o.notification_id in (select id from public.notifications where kind = 'chat.mention' and user_id = test.id('s2')))), 1,
  'mentioned user gets one push, not two');
-- token re-registration moves the device to the new account (shared phone) and re-enables it
select test.as(test.id('s3'));
select public.save_fcm('tok-s1-aaaaaaaaaaaaaaaaaaaaaaaa', 'en');
select test.as_db();
select test.eq((select user_id from public.push_devices where token = 'tok-s1-aaaaaaaaaaaaaaaaaaaaaaaa'), test.id('s3'), 'token belongs to the account that registered it last');
select test.ok(exists(select 1 from public.notify_kinds where kind = 'pres.topics' and lang = 'az'), 'push text for the new topic event');
