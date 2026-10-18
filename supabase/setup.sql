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

-- Crew picture: one of the built-in pictures (0-5). -1 means "pick one from the invite code".
alter table public.crews add column if not exists pic smallint not null default -1;

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
    'pic', c.pic,
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

create or replace function public.crew_set_pic(p_code text, p_member_id uuid, p_token uuid, p_pic int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare cid uuid;
begin
  cid := public.crew_check_member(p_code, p_member_id, p_token);
  if p_pic is null or p_pic < 0 or p_pic > 15 then raise exception 'bad_pic' using errcode = 'P0001'; end if;
  update public.crews set pic = p_pic where id = cid;
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
  public.crew_leave(text, uuid, uuid), public.crew_set_pic(text, uuid, uuid, int) from public;
grant execute on function public.crew_create(text, text), public.crew_join(text, text), public.crew_state(text),
  public.crew_rsvp(text, uuid, uuid, text, text), public.crew_set_free(text, uuid, uuid, date, boolean),
  public.crew_leave(text, uuid, uuid), public.crew_set_pic(text, uuid, uuid, int) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Friends: people you know outside your crew. Friendship is mutual and starts when someone
-- opens your friend link (or scans your QR code) and taps Add. Friends see each other's plans.
-- Same rules as crews: the website can only call the friend_* functions, never the tables.

create table if not exists public.fr_people (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null check (char_length(name) between 1 and 30),
  token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table if not exists public.fr_links (
  person_id uuid not null references public.fr_people(id) on delete cascade,
  friend_id uuid not null references public.fr_people(id) on delete cascade,
  note text check (note is null or char_length(note) <= 40),
  created_at timestamptz not null default now(),
  primary key (person_id, friend_id),
  check (person_id <> friend_id)
);
create index if not exists fr_links_friend_idx on public.fr_links (friend_id);

create table if not exists public.fr_plans (
  person_id uuid not null references public.fr_people(id) on delete cascade,
  event_id text not null check (char_length(event_id) between 1 and 80),
  status text not null check (status in ('going', 'interested', 'tix')),
  updated_at timestamptz not null default now(),
  primary key (person_id, event_id)
);

alter table public.fr_people enable row level security;
alter table public.fr_links enable row level security;
alter table public.fr_plans enable row level security;
revoke all on public.fr_people, public.fr_links, public.fr_plans from anon, authenticated;

create or replace function public.friend_check(p_id uuid, p_token uuid) returns void
language plpgsql stable set search_path = public as $$
begin
  if not exists (select 1 from public.fr_people where id = p_id and token = p_token) then
    raise exception 'not_a_person' using errcode = 'P0001';
  end if;
end $$;

create or replace function public.friend_plans_json(p_person uuid) returns json
language sql stable set search_path = public as $$
  select coalesce(json_agg(json_build_object('event_id', event_id, 'status', status)), '[]'::json)
  from public.fr_plans where person_id = p_person
$$;

create or replace function public.friend_create(p_name text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  nm text := public.crew_clean_name(p_name, 30);
  pid uuid; pcode text; ptoken uuid; tries int := 0;
begin
  if nm is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  loop
    tries := tries + 1;
    begin
      insert into public.fr_people (code, name) values (public.crew_new_code(), nm) returning id, code, token into pid, pcode, ptoken;
      exit;
    exception when unique_violation then
      if tries > 5 then raise; end if;
    end;
  end loop;
  return json_build_object('id', pid, 'token', ptoken, 'code', pcode, 'name', nm);
end $$;

-- What someone sees after opening a friend link: just the name and that person's plans.
create or replace function public.friend_lookup(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare p public.fr_people%rowtype;
begin
  select * into p from public.fr_people where code = lower(btrim(p_code));
  if p.id is null then raise exception 'friend_not_found' using errcode = 'P0001'; end if;
  return json_build_object('id', p.id, 'code', p.code, 'name', p.name, 'plans', public.friend_plans_json(p.id));
end $$;

create or replace function public.friend_add(p_id uuid, p_token uuid, p_code text, p_note text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  other public.fr_people%rowtype;
  nt text := public.crew_clean_name(p_note, 40);
  n int;
begin
  perform public.friend_check(p_id, p_token);
  select * into other from public.fr_people where code = lower(btrim(p_code));
  if other.id is null then raise exception 'friend_not_found' using errcode = 'P0001'; end if;
  if other.id = p_id then raise exception 'own_code' using errcode = 'P0001'; end if;
  select count(*) into n from public.fr_links where person_id = p_id;
  if n >= 300 then raise exception 'too_many_friends' using errcode = 'P0001'; end if;
  insert into public.fr_links (person_id, friend_id, note) values (p_id, other.id, nt)
    on conflict (person_id, friend_id) do update set note = coalesce(excluded.note, public.fr_links.note);
  insert into public.fr_links (person_id, friend_id, note) values (other.id, p_id, nt)
    on conflict (person_id, friend_id) do nothing;
  return json_build_object('id', other.id, 'name', other.name);
end $$;

create or replace function public.friend_state(p_id uuid, p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare p public.fr_people%rowtype;
begin
  perform public.friend_check(p_id, p_token);
  select * into p from public.fr_people where id = p_id;
  return json_build_object(
    'name', p.name,
    'code', p.code,
    'friends', coalesce((
      select json_agg(json_build_object('id', f.id, 'name', f.name, 'note', l.note, 'since', l.created_at,
                                        'plans', public.friend_plans_json(f.id)) order by l.created_at)
      from public.fr_links l join public.fr_people f on f.id = l.friend_id
      where l.person_id = p_id), '[]'::json)
  );
end $$;

-- Replace all of your plans at once: p_plans is {"event-id": "going", ...}
create or replace function public.friend_set_plans(p_id uuid, p_token uuid, p_plans json) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.friend_check(p_id, p_token);
  if p_plans is null or json_typeof(p_plans) <> 'object' then raise exception 'bad_plans' using errcode = 'P0001'; end if;
  if (select count(*) from json_each_text(p_plans)) > 400 then raise exception 'bad_plans' using errcode = 'P0001'; end if;
  delete from public.fr_plans where person_id = p_id;
  insert into public.fr_plans (person_id, event_id, status)
    select p_id, key, value from json_each_text(p_plans)
    where char_length(key) between 1 and 80 and value in ('going', 'interested', 'tix');
  return json_build_object('ok', true);
end $$;

create or replace function public.friend_remove(p_id uuid, p_token uuid, p_friend_id uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.friend_check(p_id, p_token);
  delete from public.fr_links where (person_id = p_id and friend_id = p_friend_id) or (person_id = p_friend_id and friend_id = p_id);
  return json_build_object('ok', true);
end $$;

create or replace function public.friend_rename(p_id uuid, p_token uuid, p_name text) returns json
language plpgsql volatile security definer set search_path = public as $$
declare nm text := public.crew_clean_name(p_name, 30);
begin
  perform public.friend_check(p_id, p_token);
  if nm is null then raise exception 'name_required' using errcode = 'P0001'; end if;
  update public.fr_people set name = nm where id = p_id;
  return json_build_object('ok', true, 'name', nm);
end $$;

revoke all on function public.friend_check(uuid, uuid), public.friend_plans_json(uuid) from public, anon, authenticated;
revoke all on function public.friend_create(text), public.friend_lookup(text), public.friend_add(uuid, uuid, text, text),
  public.friend_state(uuid, uuid), public.friend_set_plans(uuid, uuid, json), public.friend_remove(uuid, uuid, uuid),
  public.friend_rename(uuid, uuid, text) from public;
grant execute on function public.friend_create(text), public.friend_lookup(text), public.friend_add(uuid, uuid, text, text),
  public.friend_state(uuid, uuid), public.friend_set_plans(uuid, uuid, json), public.friend_remove(uuid, uuid, uuid),
  public.friend_rename(uuid, uuid, text) to anon, authenticated;
