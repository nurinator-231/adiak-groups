-- ADIAK 1.1 items 2 + 4: empty groups created by staff, supervising teacher, admin who is a student acts as a student in groups.
-- (4) an admin (perms 'admin', role student) is a normal group member
update public.profiles set perms = '{admin}' where id = test.id('s6');
select test.as(test.id('s6'));
select test.lives($q$select public.create_group('Admin Team', 4)$q$, 'admin-student can create a group');
select test.as_db();
select test.ok((select group_id is not null from public.profiles where id = test.id('s6')), 'admin-student is a member of the new group');
select test.ok((select perms from public.profiles where id = test.id('s6')) = '{admin}', 'admin rights unchanged');
update public.profiles set group_id = null where id = test.id('s6');
delete from public.groups where name = 'Admin Team';
-- the platform admin flag does not block participation either (role student + class)
update public.profiles set class_tag = 'c1' where id = test.id('admin');
select test.as(test.id('admin'));
select test.lives($q$select public.request_join(2)$q$, 'is_admin student can ask to join a group');
select test.as_db();
select test.ok(exists(select 1 from public.requests where user_id = test.id('admin') and group_id = 2), 'join request stored');
select test.lives($q$update public.profiles set group_id = 2 where id = test.id('admin')$q$, 'trigger accepts an admin in a group');
select test.ok(public._chan_ok('g:2', test.id('admin')), 'admin member reads the group chat');
update public.profiles set group_id = null, class_tag = null where id = test.id('admin');
select test.throws($q$update public.profiles set group_id = 1 where id = 'a0000000-0000-4000-8000-000000000002'$q$, 'only students', 'teachers still cannot be group members');
select test.as(test.id('s1'));
select test.lives(format($q$select public.send_invite(1, %L)$q$, test.id('s6')), 'host can invite an admin-student');
-- (2) empty groups by staff
select test.as(test.id('tpres'));
select test.lives($q$select public.admin_create_group('c1', 'Empty Team', 5)$q$, 'teacher with groups permission creates an empty group');
select test.as_db();
select id as eg from public.groups where name = 'Empty Team' \gset
select test.eq((select count(*)::int from public.profiles where group_id = :eg), 0, 'the new group has no members');
select test.ok((select host_id is null and class_tag = 'c1' and created_by = test.id('tpres') from public.groups where id = :eg), 'no host, class set, creator recorded');
select test.as(test.id('tpres'));
select test.throws($q$select public.admin_create_group('c1', 'empty team', 5)$q$, 'already exists', 'duplicate name in the class rejected');
select test.throws($q$select public.admin_create_group('c1', '', 5)$q$, '1 to 30', 'empty name rejected');
select test.throws($q$select public.admin_create_group('c1', 'X', 11)$q$, '1 to 10', 'bad size rejected');
select test.throws($q$select public.admin_create_group('c2', 'Foreign', 5)$q$, 'permission', 'teacher cannot create groups in another class');
select test.throws($q$select public.admin_create_group('zz', 'Nope', 5)$q$, 'class not found', 'unknown class rejected');
select test.as(test.id('s1'));
select test.throws($q$select public.admin_create_group('c1', 'Mine', 5)$q$, 'permission', 'student cannot use it');
-- add members later
select test.as(test.id('tpres'));
select test.lives(format('select public.admin_move_member(%L, %s)', test.id('s6'), :eg), 'staff adds a student to the empty group');
select test.as_db();
select test.ok((select host_id = test.id('s6') from public.groups where id = :eg), 'first member becomes host');
select test.as(test.id('tpres'));
select test.throws(format('select public.admin_move_member(%L, %s)', test.id('tnone'), :eg), 'only students', 'teacher cannot be added as a member');
select test.throws(format('select public.admin_move_member(%L, %s)', test.id('x1'), :eg), 'another class', 'student of another class rejected');
-- supervising teacher
select test.lives(format('select public.admin_group_set_teacher(%s, %L)', :eg, test.id('tpres')), 'staff assigns a supervising teacher');
select test.throws(format('select public.admin_group_set_teacher(%s, %L)', :eg, test.id('tother')), 'teacher of this class', 'teacher of another class rejected');
select test.as_db();
select test.ok(public._chan_ok('g:' || :eg, test.id('tpres')), 'supervising teacher can access the group chat');
select test.ok(not public._chan_ok('g:1', test.id('tpres')), 'but not other groups');
select test.ok(exists(select 1 from public.notifications where kind = 'group.teacher' and user_id = test.id('tpres')) = false, 'a teacher assigning themselves is not notified');
select test.as(test.id('tpres'));
select test.lives(format('select public.admin_delete_group(%s)', :eg), 'staff deletes the group');
select test.as_db();
select test.ok((select group_id is null from public.profiles where id = test.id('s6')), 'members become idle after delete');
