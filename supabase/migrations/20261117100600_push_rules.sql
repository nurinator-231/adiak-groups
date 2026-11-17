-- ADIAK 1.1 / item 1: push delivery rules on top of the existing pipeline (notifications/messages -> push_outbox -> push-fcm).
--   · The user who triggers an event never receives its notification (_notify skips auth.uid(); cron/service calls have no
--     caller and are unchanged). Message pushes already skip the sender.
--   · No double push: a chat.mention notification is not pushed to a device that already gets the push for that same message.
-- Token registration/refresh (save_fcm), invalid tokens (push-fcm marks them 'invalid' and disables the device), retries and
-- per-device de-duplication (unique outbox keys) already exist and are unchanged.
-- Rollback: supabase/rollback/v11_restore.sql (non-destructive; verified locally).
do $$ begin
  if to_regprocedure('public._notify(uuid[],text,jsonb,jsonb,text)') is null then raise exception 'pre-flight: notifications missing'; end if;
end $$;

create or replace function public._notify(users uuid[], k text, p jsonb, tgt jsonb, dedupe text default null) returns integer
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare n int := 0; me uuid := auth.uid();
begin
  begin
    insert into public.notifications (user_id, kind, params, target, dedupe_key)
      select distinct u, k, coalesce(p, '{}'), coalesce(tgt, '{}'), dedupe
      from unnest(users) u
      where u is not null and u is distinct from me and exists (select 1 from public.profiles pr where pr.id = u)
    on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
    get diagnostics n = row_count;
  exception when others then
    begin insert into public.notify_errors (kind, users, err) values (k, users, left(sqlerrm, 500));
    exception when others then null; end;
    n := 0;
  end;
  return n;
end $$;

create or replace function public._tg_note_outbox() returns trigger
 language plpgsql security definer set search_path = pg_catalog, public as $$
declare mid bigint;
begin
  begin
    if new.kind = 'chat.mention' and coalesce(new.target ->> 'mid', '') ~ '^[0-9]{1,18}$' then mid := (new.target ->> 'mid')::bigint; end if;
    insert into public.push_outbox (notification_id, device_id)
      select new.id, d.id from public.push_devices d where d.user_id = new.user_id and d.disabled_at is null
         and (mid is null or not exists (select 1 from public.push_outbox o where o.message_id = mid and o.device_id = d.id))
    on conflict do nothing;
    if found then perform public._push_kick(); end if;
  exception when others then
    begin insert into public.notify_errors (kind, users, err) values ('outbox:' || new.kind, array[new.user_id], left(sqlerrm, 500));
    exception when others then null; end;
  end;
  return null;
end $$;

revoke all on function public._notify(uuid[], text, jsonb, jsonb, text), public._tg_note_outbox() from public, anon, authenticated, service_role;
grant execute on function public._notify(uuid[], text, jsonb, jsonb, text) to service_role;   -- as before (cron reminders)

-- push texts for the new events and the auto-accepted choices (the app renders its own translations)
insert into public.notify_kinds (kind, lang, title, body) values
 ('pres.order_approved','en','Speaking order saved','{title}'),('pres.order_approved','az','Çıxış sırası qəbul edildi','{title}'),
 ('pres.final_approved','en','Final presentation selected (v{v})','{title}'),('pres.final_approved','az','Final təqdimat seçildi (v{v})','{title}'),
 ('pres.final_submitted','en','{team} chose final version {v}','{file}'),('pres.final_submitted','az','{team} final versiya {v} seçdi','{file}'),
 ('pres.topics','en','Topic list published: {title}','Choose your presentation topic.'),('pres.topics','az','Mövzu siyahısı: {title}','Təqdimat mövzunuzu seçin.'),
 ('pres.topic_released','en','Your topic was released','{topic} · {title}'),('pres.topic_released','az','Mövzu seçiminiz ləğv edildi','{topic} · {title}'),
 ('group.teacher','en','You supervise {group}','You can follow the group chat.'),('group.teacher','az','{group} qrupuna rəhbərlik edirsiniz','Qrup çatını izləyə bilərsiniz.')
on conflict (kind, lang) do update set title = excluded.title, body = excluded.body;
