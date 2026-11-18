-- Speaking order (ADIAK 1.2): own slot only, unique, 1..N; a complete order is accepted at once (no teacher/host approval),
-- picks stay changeable until the event is frozen, a leaver does not block the team, history and audit kept.
select test.mk_event() as e \gset
select test.as(test.id('s1'));
select test.lives(format('select public.pres_pick(%s, 1)', :e), 's1 picks position 1');
select test.throws(format('select public.pres_pick(%s, 4)', :e), 'from 1 to 3', 'position beyond team size rejected');
select test.as(test.id('s2'));
select test.throws(format('select public.pres_pick(%s, 1)', :e), 'already taken', 'occupied position rejected');
select test.lives(format('select public.pres_pick(%s, 2)', :e), 's2 picks position 2');
select test.throws(format('select public.pres_submit_order(%s)', :e), 'every member', 'incomplete order cannot be submitted');
select test.lives(format('select public.pres_pick(%s, 3)', :e), 's2 changes to position 3');
select test.as_db();
select test.eq((select position from public.pres_speakers where event_id = :e and user_id = test.id('s2')), 3, 'a normal gap keeps the chosen position (no renumbering)');
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'open', 'incomplete order stays open');
select test.as(test.id('s3'));
select test.lives(format('select public.pres_pick(%s, 2)', :e), 's3 takes freed position 2');
select test.as_db();
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'complete order accepted at once, no approval step');
select test.eq((select speak_by from public.pres_event_teams where event_id = :e and group_id = 1), test.id('s3'), 'student whose pick completed the order recorded');
select test.ok((select array_agg(action order by id) from public.pres_speaker_log where event_id = :e and group_id = 1) @> array['pick','change','auto_accept'],
  'selection history recorded (pick/change/auto_accept)');
select test.ok(exists(select 1 from public.pres_audit where entity = 'pres_speakers' and event_id = :e), 'speaker changes audited');
select test.ok(exists(select 1 from public.notifications where kind = 'pres.order_approved' and user_id = test.id('s1')), 'team told the order is saved');
select test.ok(not exists(select 1 from public.notifications where kind = 'pres.order_approved' and user_id = test.id('s3')), 'student who completed it is not notified (no self-notification)');
select test.ok(not exists(select 1 from public.notifications where kind = 'pres.order_submitted'), 'no "waiting for approval" request to staff');
-- still changeable after acceptance (until frozen): unpick reopens, pick accepts again
select test.as(test.id('s2'));
select test.lives(format('select public.pres_submit_order(%s)', :e), 'older clients: submit on a complete order is a harmless no-op');
select test.lives(format('select public.pres_unpick(%s)', :e), 's2 frees position 3 after acceptance');
select test.as_db();
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'open', 'order open again while incomplete');
select test.as(test.id('s2'));
select test.lives(format('select public.pres_pick(%s, 3)', :e), 's2 picks again');
select test.as_db();
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'accepted again without approval');
-- staff keep their powers: reopen
select test.as(test.id('s1'));
select test.throws(format('select public.pres_return_order(%s, 1, ''x'')', :e), 'only be reopened by staff', 'host cannot reopen an accepted order');
select test.as(test.id('tpres'));
select test.lives(format('select public.pres_return_order(%s, 1, ''please swap 1 and 2'')', :e), 'staff reopens an accepted order');
select test.as_db();
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'open', 'order open again for revision');
select test.as(test.id('s1'));
select test.lives(format('select public.pres_pick(%s, 1)', :e), 'a pick after staff reopened settles again');
select test.as_db();
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'complete order accepted again');
-- a member who leaves no longer blocks the team: s2 (position 3) leaves, picks 1..2 still fit -> still accepted
update public.profiles set group_id = null where id = test.id('s2');
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'leaver at the last position: remaining order still complete and accepted');
select test.ok(not exists(select 1 from public.pres_speakers where event_id = :e and user_id = test.id('s2')), 'leaver pick removed');
-- s3 (position 2) leaves too: s1 keeps 1, order of one member complete
update public.profiles set group_id = null where id = test.id('s3');
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'second leaver: one-member order still accepted');
-- a newcomer without a pick reopens the order; the newcomer's pick accepts it
update public.profiles set group_id = 1 where id = test.id('s2');
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'open', 'newcomer without a pick reopens the order');
-- renumbering when a pick no longer fits: s1 takes 2, s2 takes 1, then s2 leaves -> s1 renumbered to 1
select test.as(test.id('s1'));
select test.lives(format('select public.pres_pick(%s, 2)', :e), 's1 moves to 2');
select test.as(test.id('s2'));
select test.lives(format('select public.pres_pick(%s, 1)', :e), 's2 picks 1');
select test.as_db();
update public.profiles set group_id = null where id = test.id('s2');
select test.eq((select position from public.pres_speakers where event_id = :e and user_id = test.id('s1')), 1, 'pick above the new team size renumbered in order');
select test.eq((select speak_state from public.pres_event_teams where event_id = :e and group_id = 1), 'approved', 'renumbered order accepted');
-- positions are per team; identity checks
select test.as(test.id('s4'));
select test.lives(format('select public.pres_pick(%s, 1)', :e), 's4 (team 2) picks 1 - positions are per team');
select test.as(test.id('outsider'));
select test.throws(format('select public.pres_pick(%s, 1)', :e), 'not signed in', 'auth user without profile rejected');
select test.as(test.id('s6'));
select test.throws(format('select public.pres_pick(%s, 1)', :e), 'not in a team', 'idle student rejected');
-- frozen events: picks locked
select test.as_db();
update public.pres_events set frozen_at = now(), status = 'live' where id = :e;
select test.as(test.id('s1'));
select test.throws(format('select public.pres_pick(%s, 1)', :e), 'not in a team', 'no picks once the event is frozen');
