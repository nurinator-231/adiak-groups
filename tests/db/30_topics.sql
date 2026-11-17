-- ADIAK 1.2 item 9: topic lists uploaded by the teacher, picked by students.
select test.mk_event() as e \gset
select test.as(test.id('s1'));
select test.throws(format($q$select public.pres_topics_add(%s, array['x'])$q$, :e), 'permission', 'student cannot add topics');
select test.as(test.id('tpres'));
select test.throws(format($q$select public.pres_topics_add(%s, array['', '  ', '1.'])$q$, :e), 'no topics', 'empty list rejected');
select test.throws(format($q$select public.pres_topics_add(%s, null)$q$, :e), 'no topics', 'missing list rejected');
select test.eq(public.pres_topics_add(:e, array['1. Süni intellektin gələcəyi', '2) Kibertəhlükəsizlik', '• Bulud texnologiyaları', '', '- Verilənlər bazası', 'kibertəhlükəsizlik'], 'mövzular.docx'), 4,
  'numbering/bullets removed, blanks and duplicates skipped');
select test.as_db();
select test.eq((select array_agg(title order by position) from public.pres_topics where event_id = :e),
  array['Süni intellektin gələcəyi','Kibertəhlükəsizlik','Bulud texnologiyaları','Verilənlər bazası'], 'topics stored in file order');
select test.eq((select topics_source from public.pres_events where id = :e), 'mövzular.docx', 'source file name kept');
select test.ok(exists(select 1 from public.notifications where kind = 'pres.topics' and user_id = test.id('s1')), 'students told the topic list is published');
select id as t1 from public.pres_topics where event_id = :e and position = 1 \gset
select id as t2 from public.pres_topics where event_id = :e and position = 2 \gset
-- picking (exclusive by default)
select test.as(test.id('s1'));
select test.lives(format('select public.pres_topic_pick(%s)', :t1), 's1 picks topic 1');
select test.as(test.id('s4'));
select test.throws(format('select public.pres_topic_pick(%s)', :t1), 'already taken', 'exclusive topic cannot be taken twice');
select test.lives(format('select public.pres_topic_pick(%s)', :t2), 's4 picks topic 2');
select test.as(test.id('s1'));
select test.lives(format('select public.pres_topic_pick(%s)', :t2 + 1), 's1 changes to topic 3');
select test.as_db();
select test.eq((select count(*)::int from public.pres_topic_picks where event_id = :e and user_id = test.id('s1')), 1, 'one topic per student');
select test.as(test.id('s6'));
select test.throws(format('select public.pres_topic_pick(%s)', :t1), 'not in a team', 'student outside the teams cannot pick');
select test.as(test.id('x1'));
select test.eq((select count(*)::int from public.pres_topics where event_id = :e), 0, 'other class cannot see the topics');
-- staff view and management
select test.as(test.id('tpres'));
select test.eq((select user_name from public.pres_topic_picks where topic_id = :t2), 'Student Four', 'teacher sees who picked which topic');
select test.lives(format('select public.pres_topic_limit(%s, 2)', :e), 'teacher allows 2 students per topic');
select test.as(test.id('s5'));
select test.lives(format('select public.pres_topic_pick(%s)', :t2), 'second student can share topic 2 now');
select test.as(test.id('s2'));
select test.throws(format('select public.pres_topic_pick(%s)', :t2), 'already taken', 'third student blocked by the limit');
select test.as(test.id('tpres'));
select test.throws(format('select public.pres_topic_limit(%s, 1)', :e), 'more students', 'limit cannot go below current picks');
select test.lives(format('select public.pres_topic_edit(%s, ''Kibertəhlükəsizlik və etika'')', :t2), 'teacher renames a topic');
select test.throws(format('select public.pres_topic_edit(%s, ''Verilənlər bazası'')', :t2), 'already in the list', 'rename to a duplicate rejected');
select test.lives(format('select public.pres_topic_release(%s, %L)', :e, test.id('s5')), 'teacher releases a pick');
select test.lives(format('select public.pres_topic_remove(%s)', :t2), 'teacher removes a topic');
select test.as_db();
select test.eq((select count(*)::int from public.pres_topic_picks where topic_id = :t2), 0, 'picks of a removed topic released');
select test.ok(exists(select 1 from public.notifications where kind = 'pres.topic_released' and user_id = test.id('s4')), 'student told the topic was released');
select test.ok((select removed_at is not null from public.pres_topics where id = :t2), 'removed topic kept as history');
-- locked when frozen
update public.pres_events set frozen_at = now(), status = 'live' where id = :e;
select test.as(test.id('s4'));
select test.throws(format('select public.pres_topic_pick(%s)', :t1), 'not in a team|locked', 'no picks once the presentation is live');
select test.throws(format('select public.pres_topic_unpick(%s)', :e), 'locked', 'no unpick once live');
