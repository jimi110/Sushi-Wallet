-- =====================================================================
-- Wrapped · almacenamiento TEMPORAL (v2). Sustituye al wrapped.sql anterior.
-- Supabase solo mantiene salas vivas y sincroniza en tiempo real.
-- Al terminar la partida y confirmar todos la recompensa, se BORRAN todos
-- los registros de la sala. El esquema (tablas, funciones, RLS) permanece.
-- AVISO: este script recrea las tablas wr_*; borra salas Wrapped en curso.
-- =====================================================================
create extension if not exists pgcrypto;

drop table if exists wr_roulette, wr_presence, wr_result_players, wr_results, wr_items, wr_players, wr_rooms cascade;

create table wr_rooms(
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  host_id uuid not null,
  status text not null default 'waiting' check (status in ('waiting','active','finalizing','completed','expired')),
  max_players int not null default 4,
  started_at timestamptz,
  countdown_at timestamptz,            -- instante (reloj del servidor) en que empezó la cuenta atrás; null = no hay
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table wr_players(
  room_id uuid not null references wr_rooms(id) on delete cascade,
  user_id uuid not null,
  nick text not null default 'Jugador',
  status text not null default 'playing' check (status in ('playing','finished','left','kicked')), -- finished = «Listo»
  joined_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(room_id,user_id));
create unique index wr_players_one_open_room on wr_players(user_id) where status in ('playing','finished');

create table wr_items(
  room_id uuid not null references wr_rooms(id) on delete cascade,
  user_id uuid not null,
  dish_id text not null,
  dish_name text not null,
  qty int not null check (qty between 0 and 99),
  unit_cents int not null check (unit_cents >= 0),
  seq bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key(room_id,user_id,dish_id));

create table wr_presence(                 -- latido de conexión; NO está en la publicación Realtime
  room_id uuid not null references wr_rooms(id) on delete cascade,
  user_id uuid not null,
  last_seen timestamptz not null default now(),
  primary key(room_id,user_id));

create table wr_results(
  room_id uuid primary key references wr_rooms(id) on delete cascade,
  players int not null, global_cents bigint not null, credited_cents bigint not null,
  rule jsonb not null default '{}', created_at timestamptz not null default now());

create table wr_result_players(
  room_id uuid not null references wr_rooms(id) on delete cascade,
  user_id uuid not null,
  nick text not null, place int not null,
  contrib_cents bigint not null, base_cents bigint not null,
  bonus_pct int not null, bonus_cents bigint not null, total_cents bigint not null,
  applied_at timestamptz,                -- el navegador confirmó que guardó la recompensa
  primary key(room_id,user_id));

create table wr_roulette(
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references wr_rooms(id) on delete cascade,
  user_id uuid not null, dish_id text not null, dish_name text not null,
  dish_category text not null default '', unit_cents int not null,
  status text not null default 'pending' check (status in ('pending','accepted','dismissed')),
  updated_at timestamptz not null default now());

-- ---------- RLS: lectura solo de tu sala; toda escritura va por funciones SECURITY DEFINER ----------
alter table wr_rooms enable row level security; alter table wr_players enable row level security;
alter table wr_items enable row level security; alter table wr_presence enable row level security;
alter table wr_results enable row level security; alter table wr_result_players enable row level security;
alter table wr_roulette enable row level security;

create or replace function wr_is_member(p_room uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from wr_players where room_id=p_room and user_id=auth.uid() and status in ('playing','finished')) $$;

create policy rooms_r on wr_rooms for select to authenticated using (wr_is_member(id));
create policy players_r on wr_players for select to authenticated using (wr_is_member(room_id) or user_id=auth.uid());
create policy items_r on wr_items for select to authenticated using (wr_is_member(room_id));
create policy res_r on wr_results for select to authenticated using (wr_is_member(room_id));
create policy resp_r on wr_result_players for select to authenticated using (wr_is_member(room_id));
create policy roul_r on wr_roulette for select to authenticated using (user_id=auth.uid());
revoke all on wr_presence from anon, authenticated;   -- sin política: nadie la lee desde el navegador

do $$ begin
  begin alter publication supabase_realtime add table wr_rooms, wr_players, wr_items, wr_results, wr_result_players, wr_roulette;
  exception when duplicate_object then null; end;
end $$;
alter table wr_rooms replica identity full; alter table wr_players replica identity full;

-- ---------- Utilidades ----------
create or replace function wr_bonus_pct(p_place int, p_n int) returns int language sql immutable as $$
  select case when p_n < 2 then 0 else case p_place when 1 then 15 when 2 then 10 when 3 then 5 else 0 end end $$;

create or replace function wr_touch() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
create trigger t_rooms before update on wr_rooms for each row execute function wr_touch();
create trigger t_players before update on wr_players for each row execute function wr_touch();
create trigger t_items before update on wr_items for each row execute function wr_touch();
create trigger t_roul before update on wr_roulette for each row execute function wr_touch();

-- Borra TODO lo de una sala (cascada) y verifica que no queda nada. Devuelve true solo si la verificación pasa.
create or replace function wr_wipe_room(p_room uuid) returns boolean language plpgsql security definer set search_path=public as $$
declare n int;
begin
  delete from wr_rooms where id=p_room;      -- cascada: jugadores, platos, presencia, resultados, ruleta
  select (select count(*) from wr_rooms where id=p_room)+(select count(*) from wr_players where room_id=p_room)
        +(select count(*) from wr_items where room_id=p_room)+(select count(*) from wr_presence where room_id=p_room)
        +(select count(*) from wr_results where room_id=p_room)+(select count(*) from wr_result_players where room_id=p_room)
        +(select count(*) from wr_roulette where room_id=p_room) into n;
  return n=0;
end $$;

-- Limpieza de salas abandonadas (se llama al crear sala; también puedes programarla con pg_cron)
create or replace function wr_purge_stale() returns void language plpgsql security definer set search_path=public as $$
declare r record;
begin
  for r in select id from wr_rooms where (status in ('waiting','active','finalizing','expired') and updated_at < now()-interval '12 hours')
                                      or (status='completed' and updated_at < now()-interval '7 days') loop
    perform wr_wipe_room(r.id);
  end loop;
end $$;

-- ---------- Salas ----------
create or replace function wr_create_room(p_nick text) returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); c text; rid uuid; ch text:='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int; ex uuid;
begin
  if u is null then raise exception 'not_authenticated'; end if;
  perform wr_purge_stale();
  select room_id into ex from wr_players where user_id=u and status in ('playing','finished') limit 1;
  if ex is not null then raise exception 'already_in_room' using detail=ex::text; end if;
  loop
    c:=''; for i in 1..8 loop c:=c||substr(ch,1+floor(random()*32)::int,1); end loop;
    exit when not exists(select 1 from wr_rooms where code=c);
  end loop;
  insert into wr_rooms(code,host_id) values(c,u) returning id into rid;
  insert into wr_players(room_id,user_id,nick) values(rid,u,coalesce(nullif(trim(p_nick),''),'Jugador'));
  return jsonb_build_object('room_id',rid,'code',c);
end $$;

create or replace function wr_join_room(p_code text, p_nick text) returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); r wr_rooms; n int; ex uuid; pl wr_players;
begin
  if u is null then raise exception 'not_authenticated'; end if;
  select * into r from wr_rooms where code=upper(p_code);
  if not found then raise exception 'room_not_found'; end if;
  select * into pl from wr_players where room_id=r.id and user_id=u;
  if found and pl.status='kicked' then raise exception 'kicked'; end if;
  if found and pl.status in ('playing','finished') then return jsonb_build_object('room_id',r.id,'rejoined',true); end if;
  select room_id into ex from wr_players where user_id=u and status in ('playing','finished') limit 1;
  if ex is not null then raise exception 'already_in_room' using detail=ex::text; end if;
  if r.status in ('active','finalizing') then raise exception 'room_started'; end if;
  if r.status<>'waiting' then raise exception 'room_closed'; end if;
  select count(*) into n from wr_players where room_id=r.id and status in ('playing','finished');
  if n>=r.max_players then raise exception 'room_full'; end if;
  insert into wr_players(room_id,user_id,nick) values(r.id,u,coalesce(nullif(trim(p_nick),''),'Jugador'))
    on conflict(room_id,user_id) do update set status='playing',nick=excluded.nick,joined_at=now();
  return jsonb_build_object('room_id',r.id,'rejoined',false);
end $$;

create or replace function wr_start_room(p_room uuid) returns void language plpgsql security definer set search_path=public as $$
declare r wr_rooms; n int;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found or r.host_id<>auth.uid() then raise exception 'not_host'; end if;
  if r.status<>'waiting' then raise exception 'room_not_waiting'; end if;
  select count(*) into n from wr_players where room_id=p_room and status='playing';
  if n<2 then raise exception 'not_enough_players'; end if;
  update wr_rooms set status='active',started_at=now(),countdown_at=null where id=p_room;
  insert into wr_presence(room_id,user_id) select room_id,user_id from wr_players where room_id=p_room and status='playing'
    on conflict do nothing;
end $$;

-- Si el anfitrión cierra la sala, pasa a 'expired' (Realtime avisa al resto) y se borra cuando el último jugador sale (wr_ack_expired).
create or replace function wr_leave_room(p_room uuid) returns void language plpgsql security definer set search_path=public as $$
declare r wr_rooms;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found then return; end if;
  if r.status<>'waiting' then raise exception 'cannot_leave'; end if;
  if r.host_id=auth.uid() then
    update wr_rooms set status='expired' where id=p_room;
    delete from wr_players where room_id=p_room and user_id=auth.uid();
    if not exists(select 1 from wr_players where room_id=p_room) then perform wr_wipe_room(p_room); end if;
  else delete from wr_players where room_id=p_room and user_id=auth.uid(); end if;
end $$;

create or replace function wr_ack_expired(p_room uuid) returns boolean language plpgsql security definer set search_path=public as $$
declare r wr_rooms;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found then return true; end if;
  if r.status<>'expired' then return false; end if;
  delete from wr_players where room_id=p_room and user_id=auth.uid();
  if not exists(select 1 from wr_players where room_id=p_room) then return wr_wipe_room(p_room); end if;
  return false;
end $$;

create or replace function wr_kick(p_room uuid, p_user uuid) returns void language plpgsql security definer set search_path=public as $$
declare r wr_rooms;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found or r.host_id<>auth.uid() then raise exception 'not_host'; end if;
  if p_user=auth.uid() then raise exception 'cannot_kick_self'; end if;
  if r.status not in ('waiting','active') then raise exception 'room_closed'; end if;
  update wr_players set status='kicked' where room_id=p_room and user_id=p_user and status in ('playing','finished');
  if not found then raise exception 'invalid_target'; end if;
  delete from wr_items where room_id=p_room and user_id=p_user;
  update wr_rooms set countdown_at=null where id=p_room;     -- cambia el grupo: la cuenta atrás se reinicia
  perform wr_eval(p_room);
end $$;

-- ---------- Platos ----------
create or replace function wr_set_item(p_room uuid,p_dish_id text,p_dish_name text,p_qty int,p_unit_cents int,p_seq bigint)
returns wr_items language plpgsql security definer set search_path=public as $$
declare r wr_rooms; pl wr_players; it wr_items;
begin
  select * into r from wr_rooms where id=p_room for share;
  if not found then raise exception 'room_not_found'; end if;
  if r.status<>'active' then raise exception 'room_not_active'; end if;
  select * into pl from wr_players where room_id=p_room and user_id=auth.uid();
  if not found or pl.status in ('left','kicked') then raise exception 'not_member'; end if;
  if pl.status<>'playing' then raise exception 'participation_closed'; end if;   -- «Listo»: no se puede modificar
  if p_qty<0 or p_qty>99 then raise exception 'invalid_quantity'; end if;
  if p_unit_cents<0 then raise exception 'invalid_points'; end if;
  if (select count(*) from wr_items where room_id=p_room and user_id=auth.uid() and dish_id<>p_dish_id)>=200 then raise exception 'too_many_items'; end if;
  insert into wr_items(room_id,user_id,dish_id,dish_name,qty,unit_cents,seq)
    values(p_room,auth.uid(),p_dish_id,left(p_dish_name,120),p_qty,p_unit_cents,p_seq)
    on conflict(room_id,user_id,dish_id) do update set qty=excluded.qty,dish_name=excluded.dish_name,seq=excluded.seq
      where wr_items.seq<=excluded.seq
    returning * into it;
  if it.room_id is null then select * into it from wr_items where room_id=p_room and user_id=auth.uid() and dish_id=p_dish_id; end if;
  return it;
end $$;

-- ---------- Ruleta ----------
create or replace function wr_roulette(p_room uuid, p_draws jsonb) returns void language plpgsql security definer set search_path=public as $$
declare r wr_rooms; d jsonb;
begin
  select * into r from wr_rooms where id=p_room for share;
  if not found or r.host_id<>auth.uid() then raise exception 'not_host'; end if;
  if r.status<>'active' then raise exception 'room_not_active'; end if;
  for d in select * from jsonb_array_elements(p_draws) loop
    if exists(select 1 from wr_players where room_id=p_room and user_id=(d->>'user_id')::uuid and status='playing') then
      insert into wr_roulette(room_id,user_id,dish_id,dish_name,dish_category,unit_cents)
      values(p_room,(d->>'user_id')::uuid,d->>'dish_id',left(d->>'dish_name',120),left(coalesce(d->>'dish_category',''),60),(d->>'unit_cents')::int);
    end if;
  end loop;
end $$;

create or replace function wr_roulette_answer(p_id uuid, p_accept boolean) returns jsonb language plpgsql security definer set search_path=public as $$
declare d wr_roulette; r wr_rooms; pl wr_players; it wr_items;
begin
  select * into d from wr_roulette where id=p_id and user_id=auth.uid() and status='pending' for update;
  if not found then raise exception 'invalid_target'; end if;
  select * into r from wr_rooms where id=d.room_id;
  select * into pl from wr_players where room_id=d.room_id and user_id=auth.uid();
  if p_accept and (r.status<>'active' or pl.status<>'playing') then raise exception 'participation_closed'; end if;
  update wr_roulette set status=case when p_accept then 'accepted' else 'dismissed' end where id=p_id;
  if p_accept then
    insert into wr_items(room_id,user_id,dish_id,dish_name,qty,unit_cents,seq)
      values(d.room_id,auth.uid(),d.dish_id,d.dish_name,1,d.unit_cents,(extract(epoch from clock_timestamp())*1000000)::bigint)
      on conflict(room_id,user_id,dish_id) do update set qty=least(99,wr_items.qty+1),seq=excluded.seq
      returning * into it;
    return jsonb_build_object('item',to_jsonb(it));
  end if;
  return jsonb_build_object('item',null);
end $$;

-- =====================================================================
-- FINALIZACIÓN REVERSIBLE + CUENTA ATRÁS VALIDADA EN EL SERVIDOR
-- Conectado = latido (wr_heartbeat) en los últimos 3,5 s. Cuenta atrás = 5 s.
-- =====================================================================
create or replace function wr_set_ready(p_room uuid, p_ready boolean) returns jsonb language plpgsql security definer set search_path=public as $$
declare r wr_rooms; pl wr_players;
begin
  select * into r from wr_rooms where id=p_room for update;                  -- serializa con wr_eval / cierre
  if not found then raise exception 'room_not_found'; end if;
  if r.status<>'active' then raise exception 'room_not_active'; end if;
  select * into pl from wr_players where room_id=p_room and user_id=auth.uid();
  if not found or pl.status in ('left','kicked') then raise exception 'not_member'; end if;
  update wr_players set status=case when p_ready then 'finished' else 'playing' end where room_id=p_room and user_id=auth.uid();
  insert into wr_presence(room_id,user_id) values(p_room,auth.uid()) on conflict(room_id,user_id) do update set last_seen=now();
  if not p_ready then update wr_rooms set countdown_at=null where id=p_room; end if;   -- desmarcarse cancela
  return wr_eval(p_room);
end $$;

-- Evalúa el estado: inicia, cancela o completa la cuenta atrás. Idempotente y atómica (bloqueo de fila).
create or replace function wr_eval(p_room uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r wr_rooms; tot int; rdy int; con int; allok boolean; left_ms int:=null;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found then return jsonb_build_object('status','gone','now',now()); end if;
  if r.status<>'active' then return jsonb_build_object('status',r.status,'now',now(),'countdown_at',r.countdown_at); end if;
  select count(*), count(*) filter (where p.status='finished'),
         count(*) filter (where pr.last_seen > now()-interval '3.5 seconds')
    into tot,rdy,con
    from wr_players p left join wr_presence pr on pr.room_id=p.room_id and pr.user_id=p.user_id
   where p.room_id=p_room and p.status in ('playing','finished');
  allok := tot>0 and rdy=tot and con=tot;
  if not allok then
    if r.countdown_at is not null then update wr_rooms set countdown_at=null where id=p_room; end if;   -- cancelada
    return jsonb_build_object('status','active','now',now(),'countdown_at',null,'players',tot,'ready',rdy,'connected',con);
  end if;
  if r.countdown_at is null then
    update wr_rooms set countdown_at=now() where id=p_room;
    return jsonb_build_object('status','active','now',now(),'countdown_at',now(),'players',tot,'ready',rdy,'connected',con);
  end if;
  if now() - r.countdown_at >= interval '5 seconds' then
    return wr_close_and_distribute(p_room);
  end if;
  return jsonb_build_object('status','active','now',now(),'countdown_at',r.countdown_at,'players',tot,'ready',rdy,'connected',con);
end $$;

create or replace function wr_heartbeat(p_room uuid) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from wr_players where room_id=p_room and user_id=auth.uid() and status in ('playing','finished')) then
    return jsonb_build_object('status','gone','now',now()); end if;
  insert into wr_presence(room_id,user_id) values(p_room,auth.uid()) on conflict(room_id,user_id) do update set last_seen=now();
  return wr_eval(p_room);
end $$;

-- Cierre y reparto: solo se ejecuta una vez (la sala pasa de 'active' a 'completed' bajo bloqueo).
create or replace function wr_close_and_distribute(p_room uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r wr_rooms; n int; g bigint; q bigint; rm bigint;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found or r.status<>'active' then return jsonb_build_object('status',coalesce(r.status,'gone'),'now',now()); end if;
  update wr_rooms set status='finalizing',countdown_at=null where id=p_room;      -- cerrada al juego
  create temp table _c on commit drop as
    select p.user_id,p.nick,p.joined_at,coalesce(sum(i.qty::bigint*i.unit_cents),0)::bigint as cents
      from wr_players p left join wr_items i on i.room_id=p.room_id and i.user_id=p.user_id
     where p.room_id=p_room and p.status in ('playing','finished') group by p.user_id,p.nick,p.joined_at;
  select count(*),coalesce(sum(cents),0) into n,g from _c;
  q:=g/n; rm:=g-q*n;
  insert into wr_result_players(room_id,user_id,nick,place,contrib_cents,base_cents,bonus_pct,bonus_cents,total_cents)
  select p_room,x.user_id,x.nick,x.place,x.cents,x.base,x.pct,x.bonus,x.base+x.bonus
    from (select y.*, (y.base*y.pct+50)/100 as bonus from (
            select c.*, 1+(select count(*) from _c o where o.cents>c.cents) as place,
                   q+(case when row_number() over(order by c.cents desc,c.joined_at,c.user_id)<=rm then 1 else 0 end) as base,
                   wr_bonus_pct((1+(select count(*) from _c o where o.cents>c.cents))::int,n) as pct
              from _c c) y) x;
  insert into wr_results(room_id,players,global_cents,credited_cents,rule)
  select p_room,n,g,coalesce(sum(total_cents),0),jsonb_build_object('bonus_pct',jsonb_build_array(15,10,5,0))
    from wr_result_players where room_id=p_room;
  -- Ya no hacen falta platos, ruleta ni presencia: solo se conserva lo imprescindible para ENTREGAR los puntos.
  delete from wr_items where room_id=p_room; delete from wr_roulette where room_id=p_room; delete from wr_presence where room_id=p_room;
  update wr_rooms set status='completed' where id=p_room;
  return jsonb_build_object('status','completed','now',now());
end $$;

-- ---------- Confirmación de recompensa y borrado ----------
-- El navegador llama aquí SOLO tras verificar que guardó los puntos en su almacenamiento local.
-- Cuando confirman todos, se borra la sala entera y se verifica el borrado antes de responder cleaned=true.
create or replace function wr_claim_reward(p_room uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r wr_rooms; m wr_result_players; pend int; ok boolean:=false;
begin
  select * into r from wr_rooms where id=p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  if r.status<>'completed' then raise exception 'room_not_active'; end if;
  select * into m from wr_result_players where room_id=p_room and user_id=auth.uid() for update;
  if not found then raise exception 'not_member'; end if;
  if m.applied_at is null then update wr_result_players set applied_at=now() where room_id=p_room and user_id=auth.uid() returning * into m; end if;
  select count(*) into pend from wr_result_players where room_id=p_room and applied_at is null;
  if pend=0 then ok:=wr_wipe_room(p_room); end if;
  return jsonb_build_object('applied_at',m.applied_at,'total_cents',m.total_cents,'cleaned',ok,'pending',pend);
end $$;

-- ¿Quedan datos de esta sala? true = verificado vacío. No revela contenido.
create or replace function wr_cleanup_check(p_room uuid) returns boolean language sql stable security definer set search_path=public as $$
  select not exists(select 1 from wr_rooms where id=p_room) and not exists(select 1 from wr_players where room_id=p_room)
     and not exists(select 1 from wr_result_players where room_id=p_room) and not exists(select 1 from wr_results where room_id=p_room)
     and not exists(select 1 from wr_items where room_id=p_room) and not exists(select 1 from wr_roulette where room_id=p_room)
     and not exists(select 1 from wr_presence where room_id=p_room) $$;

-- Para la Edge Function (service_role): ¿esta identidad aún figura en alguna sala?
create or replace function wr_user_in_any_room(p_user uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from wr_players where user_id=p_user) or exists(select 1 from wr_result_players where user_id=p_user) $$;
revoke all on function wr_user_in_any_room(uuid) from public, anon, authenticated;
revoke all on function wr_wipe_room(uuid), wr_purge_stale(), wr_eval(uuid), wr_close_and_distribute(uuid) from public, anon, authenticated;

grant execute on function wr_create_room(text), wr_join_room(text,text), wr_start_room(uuid), wr_leave_room(uuid), wr_kick(uuid,uuid),
  wr_set_item(uuid,text,text,int,int,bigint), wr_roulette(uuid,jsonb), wr_roulette_answer(uuid,boolean), wr_set_ready(uuid,boolean),
  wr_heartbeat(uuid), wr_claim_reward(uuid), wr_cleanup_check(uuid), wr_ack_expired(uuid) to authenticated;
grant execute on function wr_user_in_any_room(uuid) to service_role;
