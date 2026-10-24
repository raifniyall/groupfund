create schema if not exists gf;
revoke all on schema gf from public, anon;
grant usage on schema gf to authenticated;
create table gf.profiles(id uuid primary key references auth.users(id) on delete cascade, name text not null check(length(name) between 1 and 80), last_seen timestamptz not null default now());
create table gf.owners(email text primary key);
create table gf.groups(id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 100), created_by uuid not null references auth.users(id), invite_hash text, invite_expires timestamptz, created_at timestamptz not null default now());
create table gf.members(group_id uuid references gf.groups(id) on delete cascade,user_id uuid references auth.users(id) on delete cascade,role text not null check(role in ('admin','member')),primary key(group_id,user_id));
create index member_user_idx on gf.members(user_id);
create table gf.funds(id uuid primary key default gen_random_uuid(),group_id uuid not null references gf.groups(id),name text not null check(length(name) between 1 and 100),currency text not null check(currency ~ '^[A-Z]{3}$'),goal numeric(18,2) not null check(goal>0 and goal<=1000000000000),kind text not null check(kind in ('savings','kutu')),status text not null check(status in ('pending','active','rejected')),created_by uuid not null references auth.users(id),created_at timestamptz default now());
create index funds_group_idx on gf.funds(group_id);
create table gf.contributions(id uuid primary key, fund_id uuid not null references gf.funds(id),user_id uuid not null references auth.users(id),original_amount numeric(18,2) not null check(original_amount>0 and original_amount<=1000000000000),original_currency text not null check(original_currency ~ '^[A-Z]{3}$'),received_amount numeric(18,2) not null check(received_amount>0 and received_amount<=1000000000000),receipt_path text not null unique,notes text check(length(notes)<=1000),visibility text not null default 'members' check(visibility in ('members','admins')),status text not null default 'pending' check(status in ('pending','verified','rejected')),review_note text,reviewed_by uuid references auth.users(id),reviewed_at timestamptz,created_at timestamptz not null default now());
create index contributions_fund_idx on gf.contributions(fund_id);
create index contributions_user_idx on gf.contributions(user_id);
create table gf.messages(id uuid primary key default gen_random_uuid(),group_id uuid not null references gf.groups(id),user_id uuid not null references auth.users(id),body text not null check(length(body) between 1 and 2000),created_at timestamptz default now());
create index messages_group_idx on gf.messages(group_id,created_at desc);
create table gf.votes(id uuid primary key default gen_random_uuid(),fund_id uuid not null references gf.funds(id),title text not null check(length(title) between 1 and 200),created_by uuid not null references auth.users(id),closes_at timestamptz not null,created_at timestamptz default now());
create index votes_fund_idx on gf.votes(fund_id);
create table gf.ballots(vote_id uuid references gf.votes(id),user_id uuid references auth.users(id),choice boolean not null,primary key(vote_id,user_id));
create table gf.events(id bigint generated always as identity primary key,group_id uuid references gf.groups(id),actor uuid references auth.users(id),detail text not null,created_at timestamptz default now());
create index events_group_idx on gf.events(group_id,created_at desc);
alter table gf.profiles enable row level security;
alter table gf.owners enable row level security;
alter table gf.groups enable row level security;
alter table gf.members enable row level security;
alter table gf.funds enable row level security;
alter table gf.contributions enable row level security;
alter table gf.messages enable row level security;
alter table gf.votes enable row level security;
alter table gf.ballots enable row level security;
alter table gf.events enable row level security;
-- All product access passes through explicitly authorized RPC commands. No direct table grants.
revoke all on all tables in schema gf from public,anon,authenticated;
create function gf.is_member(g uuid) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from gf.members where group_id=g and user_id=auth.uid())$$;
create function gf.is_admin(g uuid) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from gf.members where group_id=g and user_id=auth.uid() and role='admin')$$;
create function gf.is_owner() returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from auth.users u join gf.owners o on lower(u.email)=lower(o.email) where u.id=auth.uid() and u.email_confirmed_at is not null)$$;
create function gf.receipt_access(path text) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from gf.contributions c join gf.funds f on f.id=c.fund_id where c.receipt_path=path and gf.is_member(f.group_id) and (c.user_id=auth.uid() or gf.is_admin(f.group_id)))$$;
create function gf.command(cmd text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); g uuid; f gf.funds; c gf.contributions; v gf.votes; new_id uuid; code text; val text; result jsonb; days integer;
begin
 if u is null or not exists(select 1 from auth.users where id=u and email_confirmed_at is not null) then raise exception 'Please confirm your email and sign in.'; end if;
 if cmd='profile' then
  insert into gf.profiles(id,name) values(u,left(coalesce(nullif(trim(p->>'name'),''),'Family member'),80)) on conflict(id) do update set name=excluded.name,last_seen=now();return '{}'::jsonb;
 elsif cmd='create_group' then
  insert into gf.groups(name,created_by) values(trim(p->>'name'),u) returning id into g;
  insert into gf.members values(g,u,'admin');return jsonb_build_object('group_id',g);
 elsif cmd='join_group' then
  select id into g from gf.groups where invite_hash=md5(upper(trim(p->>'code'))) and invite_expires>now();
  if g is null then raise exception 'That invitation is invalid or expired. Ask the family admin for a new one.'; end if;
  insert into gf.members values(g,u,'member') on conflict do nothing;return jsonb_build_object('group_id',g);
 elsif cmd='invite' then
  g:=(p->>'group_id')::uuid;if not gf.is_admin(g) then raise exception 'Only the group admin can invite members.';end if;
  code:=upper(replace(gen_random_uuid()::text,'-',''));update gf.groups set invite_hash=md5(code),invite_expires=now()+interval '7 days' where id=g;return jsonb_build_object('code',code,'expires','7 days');
 elsif cmd='create_fund' then
  g:=(p->>'group_id')::uuid;if not gf.is_member(g) then raise exception 'Join this group first.';end if;
  insert into gf.funds(group_id,name,currency,goal,kind,status,created_by) values(g,trim(p->>'name'),upper(p->>'currency'),(p->>'goal')::numeric,p->>'kind',case when gf.is_admin(g) then 'active' else 'pending' end,u);val:='New fund submitted';
 elsif cmd='review_fund' then
  select * into f from gf.funds where id=(p->>'id')::uuid for update;if not found or not gf.is_admin(f.group_id) then raise exception 'Only this group admin can review the fund.';end if;
  if f.status<>'pending' then raise exception 'This fund was already reviewed.';end if;
  update gf.funds set status=case when (p->>'approve')::boolean then 'active' else 'rejected' end where id=f.id;g:=f.group_id;val:='Fund request reviewed';
 elsif cmd='contribute' then
  select * into f from gf.funds where id=(p->>'fund_id')::uuid;if not found or not gf.is_member(f.group_id) or f.status<>'active' then raise exception 'Choose an active fund in your group.';end if;
  new_id:=(p->>'id')::uuid;val:=p->>'receipt_path';
  if split_part(val,'/',1)<>f.group_id::text or split_part(val,'/',2)<>u::text or split_part(split_part(val,'/',3),'.',1)<>new_id::text or not exists(select 1 from storage.objects where bucket_id='receipts' and name=val and owner_id=u::text) then raise exception 'Upload your receipt first.';end if;
  if upper(p->>'original_currency')=f.currency and (p->>'original_amount')::numeric<>(p->>'received_amount')::numeric then raise exception 'For the same currency, the received amount must match the contribution.';end if;
  insert into gf.contributions(id,fund_id,user_id,original_amount,original_currency,received_amount,receipt_path,notes,visibility) values(new_id,f.id,u,(p->>'original_amount')::numeric,upper(p->>'original_currency'),(p->>'received_amount')::numeric,val,p->>'notes',coalesce(p->>'visibility','members'));g:=f.group_id;val:='Payment receipt submitted for verification';
 elsif cmd='review_contribution' then
  select * into c from gf.contributions where id=(p->>'id')::uuid for update;select * into f from gf.funds where id=c.fund_id;
  if c.id is null or not gf.is_admin(f.group_id) then raise exception 'Only this group admin can verify receipts.';end if;
  if c.status<>'pending' then raise exception 'This contribution has already been reviewed.';end if;
  update gf.contributions set status=case when (p->>'approve')::boolean then 'verified' else 'rejected' end,review_note=left(p->>'note',1000),reviewed_by=u,reviewed_at=now() where id=c.id;g:=f.group_id;val:='Contribution reviewed';
 elsif cmd='message' then
  g:=(p->>'group_id')::uuid;if not gf.is_member(g) then raise exception 'Join the group first.';end if;
  insert into gf.messages(group_id,user_id,body) values(g,u,trim(p->>'body'));return '{}'::jsonb;
 elsif cmd='create_vote' then
  select * into f from gf.funds where id=(p->>'fund_id')::uuid;days:=(p->>'days')::integer;
  if f.id is null or not gf.is_member(f.group_id) or f.status<>'active' or days not between 3 and 14 then raise exception 'Choose an active family fund and 3–14 days.';end if;
  insert into gf.votes(fund_id,title,created_by,closes_at) values(f.id,trim(p->>'title'),u,now()+make_interval(days=>days));g:=f.group_id;val:='New family vote opened';
 elsif cmd='vote' then
  select * into v from gf.votes where id=(p->>'id')::uuid for update;select * into f from gf.funds where id=v.fund_id;
  if v.id is null or not gf.is_member(f.group_id) or v.closes_at<=now() or not exists(select 1 from gf.contributions where fund_id=f.id and user_id=u and status='verified' and reviewed_at<=v.created_at) then raise exception 'Voting is for members with a verified contribution before this vote opened, and only before its deadline.';end if;
  insert into gf.ballots values(v.id,u,(p->>'choice')::boolean);return '{}'::jsonb;
 elsif cmd='snapshot' then
  update gf.profiles set last_seen=now() where id=u;
  return jsonb_build_object('user_id',u,'owner',gf.is_owner(),'groups',(select coalesce(jsonb_agg(jsonb_build_object('id',gg.id,'name',gg.name,'role',m.role)),'[]'::jsonb) from gf.groups gg join gf.members m on gg.id=m.group_id where m.user_id=u),'funds',(select coalesce(jsonb_agg(to_jsonb(ff)||jsonb_build_object('balance',(select coalesce(sum(received_amount),0) from gf.contributions where fund_id=ff.id and status='verified'))),'[]'::jsonb) from gf.funds ff where gf.is_member(ff.group_id)));
 elsif cmd='group_data' then
  g:=(p->>'group_id')::uuid;if not gf.is_member(g) then raise exception 'You cannot open this group.';end if;
  return jsonb_build_object('members',(select coalesce(jsonb_agg(jsonb_build_object('name',pr.name,'role',m.role)),'[]'::jsonb) from gf.members m left join gf.profiles pr on pr.id=m.user_id where m.group_id=g),'contributions',(select coalesce(jsonb_agg(to_jsonb(cc)||jsonb_build_object('member_name',pr.name,'receipt_path',case when cc.user_id=u or gf.is_admin(g) then cc.receipt_path else null end) order by cc.created_at desc),'[]'::jsonb) from gf.contributions cc join gf.funds ff on ff.id=cc.fund_id left join gf.profiles pr on pr.id=cc.user_id where ff.group_id=g and (cc.visibility='members' or cc.user_id=u or gf.is_admin(g))),'messages',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select mm.body,mm.created_at,pr.name from gf.messages mm left join gf.profiles pr on pr.id=mm.user_id where mm.group_id=g order by mm.created_at desc limit 100)x),'votes',(select coalesce(jsonb_agg(to_jsonb(vv)||jsonb_build_object('yes',(select count(*) from gf.ballots where vote_id=vv.id and choice),'no',(select count(*) from gf.ballots where vote_id=vv.id and not choice),'voted',exists(select 1 from gf.ballots where vote_id=vv.id and user_id=u),'eligible',exists(select 1 from gf.contributions where fund_id=vv.fund_id and user_id=u and status='verified' and reviewed_at<=vv.created_at))),'[]'::jsonb) from gf.votes vv join gf.funds ff on ff.id=vv.fund_id where ff.group_id=g),'events',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select detail,created_at from gf.events where group_id=g order by created_at desc limit 50)x));
 elsif cmd='owner' then
  if not gf.is_owner() then raise exception 'This dashboard is only for the website owner.';end if;
  return jsonb_build_object('users',(select count(*) from auth.users),'groups',(select count(*) from gf.groups),'funds',(select count(*) from gf.funds),'pending',(select count(*) from gf.contributions where status='pending'),'active_7d',(select count(*) from gf.profiles where last_seen>now()-interval '7 days'),'accounts',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select email,created_at,last_sign_in_at from auth.users order by created_at desc limit 100)x));
 else raise exception 'Unknown action.';
 end if;
 insert into gf.events(group_id,actor,detail) values(g,u,val);return '{}'::jsonb;
end$$;
revoke all on all functions in schema gf from public,anon,authenticated;
grant execute on function gf.is_member(uuid),gf.is_admin(uuid),gf.receipt_access(text),gf.command(text,jsonb) to authenticated;
create function public.groupfund(cmd text,p jsonb default '{}'::jsonb) returns jsonb language sql security invoker set search_path='' as $$select gf.command(cmd,p)$$;
revoke all on function public.groupfund(text,jsonb) from public,anon;
grant execute on function public.groupfund(text,jsonb) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('receipts','receipts',false,5242880,array['image/jpeg','image/png','application/pdf']);
create policy receipt_insert on storage.objects for insert to authenticated with check(bucket_id='receipts' and split_part(name,'/',2)=(select auth.uid())::text and exists(select 1 from gf.members where group_id::text=split_part(name,'/',1) and user_id=(select auth.uid())));
-- Use a membership helper to avoid granting direct private table access to Storage.
drop policy receipt_insert on storage.objects;
create function gf.upload_allowed(path text) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and split_part(path,'/',2)=auth.uid()::text and exists(select 1 from gf.members where group_id::text=split_part(path,'/',1) and user_id=auth.uid())$$;
revoke all on function gf.upload_allowed(text) from public,anon;
grant execute on function gf.upload_allowed(text) to authenticated;
create policy receipt_insert on storage.objects for insert to authenticated with check(bucket_id='receipts' and gf.upload_allowed(name));
create policy receipt_read on storage.objects for select to authenticated using(bucket_id='receipts' and gf.receipt_access(name));
create policy receipt_cleanup on storage.objects for delete to authenticated using(bucket_id='receipts' and owner_id=(select auth.uid())::text and not exists(select 1 from gf.contributions where receipt_path=name));
drop policy receipt_cleanup on storage.objects;
-- No client deletion of recorded evidence. Orphan uploads are cleaned by the operator.
