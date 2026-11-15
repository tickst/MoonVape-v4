-- Рассылка о наличии больше не зависит от старого пользовательского переключателя.
-- Получатели: пользователи, запустившие бота в выбранном городе и не заблокировавшие его.
create or replace function create_broadcast(p_actor bigint, p_city text, p_text text, p_product_ids uuid[], p_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b broadcasts%rowtype; n int;
begin
  perform _assert_role(p_actor, p_city);
  select * into b from broadcasts where idempotency_key=p_key;
  if found then return jsonb_build_object('id',b.id,'recipients',b.recipients,'duplicate',true); end if;
  if nullif(trim(coalesce(p_text,'')),'') is null then raise exception 'empty_text'; end if;
  perform pg_advisory_xact_lock(hashtext('broadcast:'||p_city));
  if exists(select 1 from broadcasts where city_id=p_city and created_at > now()-interval '10 minutes') then
    raise exception 'broadcast_cooldown';
  end if;
  insert into broadcasts(city_id,text,product_ids,created_by,idempotency_key)
  values(p_city,p_text,coalesce(p_product_ids,'{}'),p_actor,p_key) returning * into b;
  insert into outbox(chat_id,kind,text,broadcast_id)
  select u.telegram_id,'broadcast',p_text,b.id from users u
  where u.city_id=p_city and u.bot_started_at is not null and not u.bot_blocked;
  get diagnostics n = row_count;
  update broadcasts set recipients=n where id=b.id;
  return jsonb_build_object('id',b.id,'recipients',n,'duplicate',false);
end $$;

revoke execute on function create_broadcast(bigint,text,text,uuid[],text) from public, anon, authenticated;
grant execute on function create_broadcast(bigint,text,text,uuid[],text) to service_role;
