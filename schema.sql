-- Muster: run this whole file once in Supabase > SQL Editor.
create table organizations(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  join_code text not null unique,
  created_at timestamptz not null default now());

create table profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid not null references organizations(id) on delete cascade,
  full_name text not null,
  role text not null default 'employee' check (role in ('admin','manager','employee')),
  manager_id uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now());

create table leave_types(
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  days_per_year numeric not null default 0 check (days_per_year>=0)); -- 0 = no limit

create table leave_requests(
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  employee_id uuid not null references profiles(id) on delete cascade,
  leave_type_id uuid not null references leave_types(id),
  start_date date not null, end_date date not null,
  days numeric not null check (days>0),
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  approver_id uuid references profiles(id),
  decision_note text, decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_date>=start_date));
create index on leave_requests(org_id,status);
create index on leave_requests(employee_id);

-- Helpers used by the access rules (security definer avoids recursive policies)
create function my_org() returns uuid language sql stable security definer set search_path=public as $$ select org_id from profiles where id=auth.uid() $$;
create function my_role() returns text language sql stable security definer set search_path=public as $$ select role from profiles where id=auth.uid() $$;
create function manages(emp uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=emp and manager_id=auth.uid()) $$;

-- Row-level security: every company only ever sees its own rows
alter table organizations enable row level security;
alter table profiles enable row level security;
alter table leave_types enable row level security;
alter table leave_requests enable row level security;
create policy org_read on organizations for select using (id=my_org());
create policy prof_read on profiles for select using (id=auth.uid() or org_id=my_org());
create policy prof_admin_update on profiles for update using (my_role()='admin' and org_id=my_org()) with check (org_id=my_org());
create policy types_read on leave_types for select using (org_id=my_org());
create policy lr_read on leave_requests for select using (employee_id=auth.uid() or (org_id=my_org() and (my_role()='admin' or manages(employee_id))));
-- No insert/update/delete policies on leave_requests: all changes go through the functions below.

create function create_organization(p_org text,p_name text) returns text language plpgsql security definer set search_path=public as $$
declare o uuid; c text;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists(select 1 from profiles where id=auth.uid()) then raise exception 'You already belong to a company'; end if;
  if length(trim(p_org))=0 or length(trim(p_name))=0 then raise exception 'Enter a company name and your name'; end if;
  c:=upper(substr(md5(gen_random_uuid()::text),1,10));
  insert into organizations(name,join_code) values(trim(p_org),c) returning id into o;
  insert into profiles(id,org_id,full_name,role) values(auth.uid(),o,trim(p_name),'admin');
  insert into leave_types(org_id,name,days_per_year) values(o,'Annual leave',14),(o,'Sick leave',10),(o,'Unpaid leave',0);
  return c;
end $$;

create function join_organization(p_code text,p_name text) returns void language plpgsql security definer set search_path=public as $$
declare o uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists(select 1 from profiles where id=auth.uid()) then raise exception 'You already belong to a company'; end if;
  select id into o from organizations where join_code=upper(trim(p_code));
  if o is null then raise exception 'That join code was not found'; end if;
  if length(trim(p_name))=0 then raise exception 'Enter your name'; end if;
  insert into profiles(id,org_id,full_name) values(auth.uid(),o,trim(p_name));
end $$;

create function request_leave(p_type uuid,p_start date,p_end date,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare me profiles; lt leave_types; n numeric; used numeric;
begin
  select * into me from profiles where id=auth.uid();
  if me.id is null then raise exception 'Finish setting up your profile first'; end if;
  select * into lt from leave_types where id=p_type and org_id=me.org_id;
  if lt.id is null then raise exception 'Unknown leave type'; end if;
  if p_end<p_start then raise exception 'The end date is before the start date'; end if;
  if extract(year from p_start)<>extract(year from p_end) then raise exception 'Split requests that cross New Year into two'; end if;
  select count(*) into n from generate_series(p_start,p_end,interval '1 day') d where extract(isodow from d)<6;
  if n=0 then raise exception 'Those dates are all weekend days'; end if;
  select coalesce(sum(days),0) into used from leave_requests where employee_id=me.id and leave_type_id=lt.id and status in ('pending','approved') and extract(year from start_date)=extract(year from p_start);
  if lt.days_per_year>0 and used+n>lt.days_per_year then raise exception 'Only % day(s) left for %',lt.days_per_year-used,lt.name; end if;
  if exists(select 1 from leave_requests where employee_id=me.id and status in ('pending','approved') and daterange(start_date,end_date,'[]') && daterange(p_start,p_end,'[]')) then raise exception 'You already have leave on some of those dates'; end if;
  insert into leave_requests(org_id,employee_id,leave_type_id,start_date,end_date,days,reason) values(me.org_id,me.id,lt.id,p_start,p_end,n,nullif(trim(p_reason),''));
end $$;

create function decide_leave(p_id uuid,p_approve boolean,p_note text) returns void language plpgsql security definer set search_path=public as $$
declare r leave_requests; me profiles;
begin
  select * into me from profiles where id=auth.uid();
  select * into r from leave_requests where id=p_id for update;
  if r.id is null or r.org_id is distinct from me.org_id then raise exception 'Request not found'; end if;
  if r.status<>'pending' then raise exception 'This request was already %',r.status; end if;
  if r.employee_id=me.id then raise exception 'You cannot decide your own request'; end if;
  if not (me.role='admin' or manages(r.employee_id)) then raise exception 'You are not the approver for this person'; end if;
  update leave_requests set status=case when p_approve then 'approved' else 'rejected' end, approver_id=me.id, decision_note=nullif(trim(p_note),''), decided_at=now() where id=p_id;
end $$;

create function cancel_leave(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update leave_requests set status='cancelled' where id=p_id and employee_id=auth.uid() and status='pending';
  if not found then raise exception 'Only your own pending requests can be cancelled'; end if;
end $$;

create view leave_balances with (security_invoker=true) as
select p.id as employee_id, lt.id as leave_type_id, lt.name, lt.days_per_year,
  coalesce(sum(r.days) filter (where r.status='approved'),0) as used,
  coalesce(sum(r.days) filter (where r.status='pending'),0) as pending
from profiles p
join leave_types lt on lt.org_id=p.org_id
left join leave_requests r on r.employee_id=p.id and r.leave_type_id=lt.id and extract(year from r.start_date)=extract(year from now())
group by p.id, lt.id, lt.name, lt.days_per_year;
