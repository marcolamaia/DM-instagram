alter table app.instagram_accounts add column insights_permission text not null default 'unknown';
create table app.account_snapshots(id uuid primary key default gen_random_uuid(),account_id uuid not null references app.instagram_accounts(id),observed_on date not null,metrics jsonb not null,synced_at timestamptz not null default now(),unique(account_id,observed_on));
create table app.media_snapshots(id uuid primary key default gen_random_uuid(),account_id uuid not null references app.instagram_accounts(id),media_id text not null,caption text,permalink text,media_type text,published_at timestamptz,metrics jsonb not null,synced_at timestamptz not null default now(),unique(account_id,media_id));
create table app.insight_sync_jobs(id uuid primary key default gen_random_uuid(),account_id uuid not null references app.instagram_accounts(id),kind text not null check(kind in ('account','media')),status text not null default 'pending',attempts integer not null default 0,scheduled_at timestamptz not null default now(),created_at timestamptz not null default now(),finished_at timestamptz,last_error text,claimed_at timestamptz,lease_token uuid);
create unique index insight_jobs_active on app.insight_sync_jobs(account_id,kind) where status in ('pending','running');
create table app.tracked_destinations(id uuid primary key default gen_random_uuid(),account_id uuid not null references app.instagram_accounts(id),run_id uuid not null references app.flow_runs(id),node_id text not null,url text not null,expires_at timestamptz not null default now()+interval '90 days',created_at timestamptz not null default now(),unique(run_id,node_id));
create table app.link_observations(id uuid primary key default gen_random_uuid(),account_id uuid not null references app.instagram_accounts(id),destination_id uuid not null references app.tracked_destinations(id),scanner boolean not null,observed_at timestamptz not null default now());
create index link_observations_account on app.link_observations(account_id,observed_at);
create function app.request_insight_sync(p_account_id uuid,p_manual boolean default false) returns void language plpgsql set search_path='' as $$
declare k text; last_at timestamptz;
begin
 perform 1 from app.instagram_accounts where id=p_account_id and connection_status='connected' for update;
 if not found then return;end if;
 foreach k in array array['account','media'] loop
  select max(created_at) into last_at from app.insight_sync_jobs where account_id=p_account_id and kind=k;
  if last_at is null or last_at<=now()-(case when p_manual then interval '5 minutes' when k='account' then interval '24 hours' else interval '6 hours' end) then
   insert into app.insight_sync_jobs(account_id,kind) values(p_account_id,k) on conflict do nothing;
  end if;
 end loop;
end $$;
create function app.claim_insight_job() returns setof app.insight_sync_jobs language plpgsql set search_path='' as $$
begin
 update app.insight_sync_jobs set status=case when attempts>=3 then 'failed' else 'pending' end,lease_token=null,last_error=case when attempts>=3 then 'abandoned_final_attempt' else 'interrupted_collect_retry' end,scheduled_at=now(),finished_at=case when attempts>=3 then now() else null end where status='running' and claimed_at<now()-interval '15 minutes';
 return query with target as (select id from app.insight_sync_jobs where status='pending' and scheduled_at<=now() order by created_at for update skip locked limit 1)
 update app.insight_sync_jobs j set status='running',attempts=attempts+1,claimed_at=now(),lease_token=gen_random_uuid() from target where j.id=target.id returning j.*;
end $$;
create function app.direct_funnel(p_account_id uuid,p_days integer,p_campaign_id uuid default null) returns jsonb language sql set search_path='' as $$
 with runs as(select r.* from app.flow_runs r join app.flow_revisions rev on rev.id=r.revision_id where r.account_id=p_account_id and (p_campaign_id is null or rev.automation_id=p_campaign_id)),
 transitions as(select t.*,r.contact_id from app.flow_transitions t join runs r on r.id=t.run_id where t.account_id=p_account_id and t.created_at>=now()-make_interval(days=>p_days)),
 deliveries as(select q.* from app.queue q where q.account_id=p_account_id and q.status='sent' and q.sent_at>=now()-make_interval(days=>p_days) and (p_campaign_id is null or q.automation_id=p_campaign_id)),
 clicks as(select l.*,d.run_id from app.link_observations l join app.tracked_destinations d on d.id=l.destination_id join runs r on r.id=d.run_id where l.account_id=p_account_id and not l.scanner and l.observed_at>=now()-make_interval(days=>p_days))
 select jsonb_build_object(
 'comments',(select count(distinct contact_id) from runs where source='comment' and created_at>=now()-make_interval(days=>p_days)),
 'initial_dm',(select count(distinct contact_id) from deliveries where delivery_type='private_reply'),
 'interactions',(select count(distinct contact_id) from transitions where kind='input'),
 'followers',(select count(distinct contact_id) from transitions where kind='follow_verified'),
 'links',(select count(distinct contact_id) from deliveries where payload->>'flow_kind'='link'),
 'clicks',(select count(*) from clicks),
 'click_contacts',(select count(distinct r.contact_id) from clicks c join runs r on r.id=c.run_id),
 'deliveries',(select count(*) from deliveries),
 'paused',(select count(*) from runs where status='paused'));
$$;
alter table app.account_snapshots enable row level security;alter table app.media_snapshots enable row level security;alter table app.insight_sync_jobs enable row level security;alter table app.tracked_destinations enable row level security;alter table app.link_observations enable row level security;
revoke all on app.account_snapshots,app.media_snapshots,app.insight_sync_jobs,app.tracked_destinations,app.link_observations from public,anon,authenticated;
grant all on app.account_snapshots,app.media_snapshots,app.insight_sync_jobs,app.tracked_destinations,app.link_observations to service_role;
revoke all on function app.request_insight_sync(uuid,boolean),app.claim_insight_job(),app.direct_funnel(uuid,integer,uuid) from public,anon,authenticated;
grant execute on function app.request_insight_sync(uuid,boolean),app.claim_insight_job(),app.direct_funnel(uuid,integer,uuid) to service_role;

create function app.direct_daily(p_account_id uuid,p_days integer,p_campaign_id uuid default null) returns jsonb language sql set search_path='' as $$
with days as (select generate_series((now() at time zone 'America/Sao_Paulo')::date-(p_days-1),(now() at time zone 'America/Sao_Paulo')::date,interval '1 day')::date as day),
runs as (select r.id,r.contact_id from app.flow_runs r join app.flow_revisions v on v.id=r.revision_id where r.account_id=p_account_id and (p_campaign_id is null or v.automation_id=p_campaign_id)),
inbound as(select (t.created_at at time zone 'America/Sao_Paulo')::date as day,count(distinct r.contact_id) conversations from app.flow_transitions t join runs r on r.id=t.run_id where t.account_id=p_account_id and t.kind='input' and t.created_at>=now()-make_interval(days=>p_days) group by 1),
links as(select (q.sent_at at time zone 'America/Sao_Paulo')::date as day,count(distinct q.contact_id) links from app.queue q join runs r on r.id=q.run_id where q.account_id=p_account_id and q.status='sent' and q.payload->>'flow_kind'='link' and q.sent_at>=now()-make_interval(days=>p_days) group by 1),
clicks as(select (l.observed_at at time zone 'America/Sao_Paulo')::date as day,count(distinct r.contact_id) clicks from app.link_observations l join app.tracked_destinations dest on dest.id=l.destination_id join runs r on r.id=dest.run_id where l.account_id=p_account_id and not l.scanner and l.observed_at>=now()-make_interval(days=>p_days) group by 1)
select coalesce(jsonb_agg(jsonb_build_object('day',d.day,'conversations',coalesce(i.conversations,0),'links',coalesce(q.links,0),'clicks',coalesce(c.clicks,0)) order by d.day),'[]'::jsonb) from days d left join inbound i using(day) left join links q using(day) left join clicks c using(day);
$$;
revoke all on function app.direct_daily(uuid,integer,uuid) from public,anon,authenticated;
grant execute on function app.direct_daily(uuid,integer,uuid) to service_role;
notify pgrst, 'reload schema';
