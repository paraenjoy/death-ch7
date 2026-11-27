-- 발표 당일 실시간 투표에 쓴 Supabase 스키마.
-- 실제 프로젝트에서 내보낸 정의를 정리한 것이다. PIN 해시 값은 넣지 않았다.

create table public.votes (
  voter_id   uuid primary key,
  choice     smallint check (choice >= 0 and choice <= 2),
  updated_at timestamptz default now()
);

create table public.vote_admin (
  id       integer primary key default 1 check (id = 1),
  pin_hash text,
  round    integer default 1
);

-- 정책을 두지 않고 RLS만 켠다. 브라우저(anon)는 두 테이블을 직접 읽거나 쓸 수 없고,
-- 아래 함수 세 개로만 다룬다.
alter table public.votes enable row level security;
alter table public.vote_admin enable row level security;

-- 집계: [죽어 있었다, 살아 있었다, 둘 다 아니다, 회차]
create or replace function public.vote_counts()
returns json
language sql
stable security definer
set search_path to 'public'
as $$
  select json_build_array(
    (select count(*) from public.votes where choice = 0),
    (select count(*) from public.votes where choice = 1),
    (select count(*) from public.votes where choice = 2),
    (select round from public.vote_admin where id = 1)
  );
$$;

-- 투표: 기기마다 한 표, 바꾸기는 3초 간격, 전체 400표 상한
create or replace function public.cast_vote(p_voter uuid, p_choice integer)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  prev timestamptz;
begin
  if p_voter is null or p_choice is null or p_choice < 0 or p_choice > 2 then
    raise exception 'invalid vote';
  end if;
  select updated_at into prev from public.votes where voter_id = p_voter;
  if prev is not null and now() - prev < interval '3 seconds' then
    return json_build_object('ok', false, 'reason', 'wait', 'counts', public.vote_counts());
  end if;
  if prev is null and (select count(*) from public.votes) >= 400 then
    return json_build_object('ok', false, 'reason', 'full', 'counts', public.vote_counts());
  end if;
  insert into public.votes (voter_id, choice) values (p_voter, p_choice)
  on conflict (voter_id) do update set choice = excluded.choice, updated_at = now();
  return json_build_object('ok', true, 'counts', public.vote_counts());
end;
$$;

-- 초기화: PIN의 SHA-256이 맞을 때만 표를 지우고 회차를 올린다. 틀리면 1초 늦게 답한다
create or replace function public.reset_votes(p_pin text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not exists (
    select 1 from public.vote_admin
    where pin_hash = encode(sha256(convert_to(coalesce(p_pin, ''), 'UTF8')), 'hex')
  ) then
    perform pg_sleep(1);
    return false;
  end if;
  delete from public.votes where true;
  update public.vote_admin set round = round + 1 where id = 1;
  return true;
end;
$$;

grant execute on function public.vote_counts() to anon, authenticated;
grant execute on function public.cast_vote(uuid, integer) to anon, authenticated;
grant execute on function public.reset_votes(text) to anon, authenticated;

-- 처음 한 번, 발표자 PIN의 해시를 넣는다
-- insert into public.vote_admin (pin_hash)
--   values (encode(sha256(convert_to('여기에 PIN', 'UTF8')), 'hex'));
