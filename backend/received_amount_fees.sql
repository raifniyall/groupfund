create or replace function gf.command(cmd text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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