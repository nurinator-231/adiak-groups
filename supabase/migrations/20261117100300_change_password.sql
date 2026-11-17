-- ADIAK 1.1 / item 7 (feedback #13): changing a password requires the current password, verified on the server.
-- change_my_password(cur, pw): checks the current password against auth.users (bcrypt via pgcrypto, like the existing
--   set_my_password_copy / _set_temp), then stores the new hash and the class-admin copy (_pw_save: none for admins).
--   A wrong current password returns 'wrong' instead of raising, so the attempt still counts in the rate limit
--   (5 attempts per 10 minutes); nothing is changed in that case. The signed-in session stays valid.
-- The app no longer calls supabase.auth.updateUser for this. Sign-in and claim_session are unchanged.
-- Rollback: supabase/rollback/v11_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regprocedure('public.change_my_password(text,text)') is not null then raise exception 'pre-flight: item7 already applied'; end if;
  if to_regclass('auth.users') is null then raise exception 'pre-flight: auth.users missing'; end if;
end $$;

create or replace function public.change_my_password(cur text, pw text) returns text
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := public._me_ok(); h text;
begin
  perform public._rate('pw_change', 5, 600);
  if cur is null or cur = '' then raise exception 'Enter your current password'; end if;
  if pw is null or char_length(pw) < 6 then raise exception 'At least 6 characters'; end if;
  if octet_length(pw) > 72 then raise exception 'The password is too long (max 72 characters)'; end if;
  select encrypted_password into h from auth.users where id = u;
  if h is null or h = '' or extensions.crypt(cur, h) <> h then return 'wrong'; end if;
  if pw = cur then raise exception 'The new password must be different from the current one'; end if;
  update auth.users set encrypted_password = extensions.crypt(pw, extensions.gen_salt('bf')),
    raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '{"must_change":false}'::jsonb, updated_at = now()
   where id = u;
  perform public._pw_save(u, pw, 'student');
  return 'ok';
end $$;
revoke all on function public.change_my_password(text, text) from public, anon, authenticated, service_role;
grant execute on function public.change_my_password(text, text) to authenticated;
