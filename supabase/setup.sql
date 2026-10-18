-- BassCalendar crews: run this once in Supabase (SQL Editor > New query > paste > Run).
-- Safe to run again: it replaces the functions and only creates tables that don't exist.
--
-- How access works: the website never touches these tables directly. It can only call the
-- crew_* functions below. Reading a crew needs its invite code. Changing your own RSVPs needs
-- the private token your browser got when you joined.

create table if not exists public.crews (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null check (char_length(name) between 1 and 40),
  created_at timestamptz not null default now()
);

create table if not exists public.crew_members (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 30),
  color smallint not null default 0,
  token uuid not null default gen_random_uuid(),
  joined_at timestamptz not null default now(),
  left_at timestamptz
);
create index if not exists crew_members_crew_idx on public.crew_members (crew_id);

create table if not exists public.crew_rsvps (
  member_id uuid not null references public.crew_members(id) on delete cascade,
  event_id text not null check (char_length(event_id) between 1 and 80),
  status text not null check (status in ('going', 'interested', 'tix')),
  updated_at timestamptz not null default now(),
  primary key (member_id, event_id)
);

create table if not exists public.crew_free (
  member_id uuid not null references public.crew_members(id) on delete cascade,
  night date not null,
  primary key (member_id, night)
);

-- Lock the tables: no direct reads or writes from the website.
alter table public.crews enable row level security;
alter table public.crew_members enable row level security;
alter table public.crew_rsvps enable row level security;
alter table public.crew_free enable row level security;
revoke all on public.crews, public.crew_members, public.crew_rsvps, public.crew_free from anon, authenticated;

-- Random invite code, 10 characters, no look-alike letters.
create or replace function public.crew_new_code() returns text
language plpgsql volatile set search_path = public as $$
declare
  alphabet text := 'abcdefghjkmnpqrstuvwxyz23456789';
  b bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  out text := '';
  i int;
begin
  for i in 0..9 loop
    out := out || substr(alphabet, (get_byte(b, i) % length(alphabet)) + 1, 1);
  end loop;
  return out;
end $$;

create or replace function public.crew_clean_name(p text, maxlen int) returns text
language sql immutable set search_path = public as $$
  select nullif(left(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), maxlen), '')
$$;

-- Find an active member and check their token. Returns the crew id or raises.
create or replace function public.crew_check_member(p_code text, p_member_id uuid, p_token uuid) returns uuid
language plpgsql stable set search_path = public as $$
declare cid uuid;
begin
  select c.id into cid
  from public.crews c join public.crew_members m on m.crew_id = c.id
  where c.code = lower(btrim(p_code)) and m.id = p_member_id and m.token = p_token and m.left_at is null;
  if cid is null then raise exception 'not_a_member' using errcode = 'P0001'; end if;
  return cid;
end $$;

create or replace function public.crew_create(p_crew_name text, p_member_name text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  cname text := public.crew_clean_name(p_crew_name, 40);
  mname text := public.crew_clean_name(p_member_name, 30);
  cid uuid; ccode text; mid uuid; mtoken uuid; tries int := 0;
begin
  if cname is null then raise exception 'crew_name_required' using errcode = 'P0001'; end if;
  if mname is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  loop
    tries := tries + 1;
    begin
      insert into public.crews (code, name) values (public.crew_new_code(), cname) returning id, code into cid, ccode;
      exit;
    exception when unique_violation then
      if tries > 5 then raise; end if;
    end;
  end loop;
  insert into public.crew_members (crew_id, name, color) values (cid, mname, 0) returning id, token into mid, mtoken;
  return json_build_object('code', ccode, 'crew_name', cname, 'member_id', mid, 'token', mtoken, 'name', mname);
end $$;

create or replace function public.crew_join(p_code text, p_member_name text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  mname text := public.crew_clean_name(p_member_name, 30);
  c public.crews%rowtype; n int; mid uuid; mtoken uuid;
begin
  if mname is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  select * into c from public.crews where code = lower(btrim(p_code));
  if c.id is null then raise exception 'crew_not_found' using errcode = 'P0001'; end if;
  select count(*) into n from public.crew_members where crew_id = c.id;
  if n >= 60 then raise exception 'crew_full' using errcode = 'P0001'; end if;
  insert into public.crew_members (crew_id, name, color) values (c.id, mname, n % 7) returning id, token into mid, mtoken;
  return json_build_object('code', c.code, 'crew_name', c.name, 'member_id', mid, 'token', mtoken, 'name', mname);
end $$;

create or replace function public.crew_state(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare c public.crews%rowtype;
begin
  select * into c from public.crews where code = lower(btrim(p_code));
  if c.id is null then raise exception 'crew_not_found' using errcode = 'P0001'; end if;
  return json_build_object(
    'code', c.code,
    'name', c.name,
    'members', coalesce((
      select json_agg(json_build_object('id', m.id, 'name', m.name, 'color', m.color, 'joined_at', m.joined_at) order by m.joined_at)
      from public.crew_members m where m.crew_id = c.id and m.left_at is null), '[]'::json),
    'rsvps', coalesce((
      select json_agg(json_build_object('member_id', r.member_id, 'event_id', r.event_id, 'status', r.status))
      from public.crew_rsvps r join public.crew_members m on m.id = r.member_id
      where m.crew_id = c.id and m.left_at is null), '[]'::json),
    'free', coalesce((
      select json_agg(json_build_object('member_id', f.member_id, 'night', f.night))
      from public.crew_free f join public.crew_members m on m.id = f.member_id
      where m.crew_id = c.id and m.left_at is null and f.night >= current_date - 1), '[]'::json)
  );
end $$;

create or replace function public.crew_rsvp(p_code text, p_member_id uuid, p_token uuid, p_event_id text, p_status text) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.crew_check_member(p_code, p_member_id, p_token);
  if p_event_id is null or char_length(p_event_id) not between 1 and 80 then
    raise exception 'bad_event' using errcode = 'P0001';
  end if;
  if p_status is null or p_status = '' then
    delete from public.crew_rsvps where member_id = p_member_id and event_id = p_event_id;
  elsif p_status in ('going', 'interested', 'tix') then
    insert into public.crew_rsvps (member_id, event_id, status) values (p_member_id, p_event_id, p_status)
    on conflict (member_id, event_id) do update set status = excluded.status, updated_at = now();
  else
    raise exception 'bad_status' using errcode = 'P0001';
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.crew_set_free(p_code text, p_member_id uuid, p_token uuid, p_night date, p_free boolean) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.crew_check_member(p_code, p_member_id, p_token);
  if p_free then
    insert into public.crew_free (member_id, night) values (p_member_id, p_night) on conflict do nothing;
  else
    delete from public.crew_free where member_id = p_member_id and night = p_night;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.crew_leave(p_code text, p_member_id uuid, p_token uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.crew_check_member(p_code, p_member_id, p_token);
  delete from public.crew_rsvps where member_id = p_member_id;
  delete from public.crew_free where member_id = p_member_id;
  update public.crew_members set left_at = now() where id = p_member_id;
  return json_build_object('ok', true);
end $$;

-- Only the crew_* actions are callable from the website. The helpers stay private.
revoke all on function public.crew_new_code(), public.crew_clean_name(text, int), public.crew_check_member(text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.crew_create(text, text), public.crew_join(text, text), public.crew_state(text),
  public.crew_rsvp(text, uuid, uuid, text, text), public.crew_set_free(text, uuid, uuid, date, boolean),
  public.crew_leave(text, uuid, uuid) from public;
grant execute on function public.crew_create(text, text), public.crew_join(text, text), public.crew_state(text),
  public.crew_rsvp(text, uuid, uuid, text, text), public.crew_set_free(text, uuid, uuid, date, boolean),
  public.crew_leave(text, uuid, uuid) to anon, authenticated;
