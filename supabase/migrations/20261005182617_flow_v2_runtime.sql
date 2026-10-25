create table app.flow_revisions (
 id uuid primary key default gen_random_uuid(), account_id uuid not null references app.instagram_accounts(id),
 automation_id uuid not null references app.automations(id), definition jsonb not null, calls jsonb not null default '{}',
 created_at timestamptz not null default now(), unique(id,account_id)
);
alter table app.automations add column published_revision_id uuid references app.flow_revisions(id);
create table app.flow_runs (
 id uuid primary key default gen_random_uuid(), account_id uuid not null references app.instagram_accounts(id),
 contact_id uuid not null references app.contacts(id), revision_id uuid not null references app.flow_revisions(id),
 source text not null check(source in ('comment','direct')), source_id text not null,
 state jsonb not null, version integer not null default 0, status text not null default 'running',
 due_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(account_id,contact_id,source,source_id)
);
create unique index flow_runs_one_owner on app.flow_runs(account_id,contact_id) where status not in ('completed','cancelled');
create index flow_runs_due on app.flow_runs(due_at) where status='wait_timer';
create table app.flow_transitions (
 id uuid primary key default gen_random_uuid(), account_id uuid not null references app.instagram_accounts(id),
 run_id uuid not null references app.flow_runs(id), transition_key text not null, node_id text,
 kind text not null, created_at timestamptz not null default now(), unique(run_id,transition_key)
);
alter table app.queue add column run_id uuid references app.flow_runs(id), add column node_id text;

create function app.publish_flow_v2(p_account_id uuid,p_automation_id uuid,p_definition jsonb,p_calls jsonb) returns uuid language plpgsql set search_path='' as $$
declare result uuid; item record;
begin
 perform 1 from app.automations where id=p_automation_id and account_id=p_account_id for update;
 if not found or p_definition->>'version'<>'2' then raise exception 'invalid publication'; end if;
 for item in select key,value from jsonb_each(p_calls) loop
  if not exists(select 1 from app.flow_revisions where id=item.key::uuid and account_id=p_account_id and definition=item.value) then raise exception 'invalid call revision';end if;
 end loop;
 insert into app.flow_revisions(account_id,automation_id,definition,calls) values(p_account_id,p_automation_id,p_definition,p_calls) returning id into result;
 update app.automations set published_revision_id=result,published_flow_definition=p_definition,active=true,updated_at=now() where id=p_automation_id;
 return result;
end $$;

create function app.start_flow_v2(p_account_id uuid,p_contact_id uuid,p_revision_id uuid,p_source text,p_source_id text,p_state jsonb) returns jsonb language plpgsql set search_path='' as $$
declare existing app.flow_runs; result app.flow_runs;
begin
 perform 1 from app.contacts where id=p_contact_id and account_id=p_account_id for update;
 if not found or not exists(select 1 from app.flow_revisions r join app.automations a on a.id=r.automation_id where r.id=p_revision_id and r.account_id=p_account_id and a.active) then raise exception 'invalid owner';end if;
 if exists(select 1 from app.contacts where id=p_contact_id and last_automation_id is not null and flow_source_comment_id is not null and flow_completed_at is null) then raise exception 'legacy_owner_preserved';end if;
 select * into existing from app.flow_runs where account_id=p_account_id and contact_id=p_contact_id and status not in ('completed','cancelled') for update;
 if found then
  perform 1 from app.queue where run_id=existing.id and status in ('pending','sending') for update;
  if p_source='comment' and existing.source='direct' and not exists(select 1 from app.queue where run_id=existing.id and status='sending') then
   update app.flow_runs set status='cancelled',state=jsonb_set(state,'{status}','"cancelled"'),updated_at=now() where id=existing.id;
   update app.queue set status='skipped',last_error='campaign_took_ownership' where run_id=existing.id and status='pending';
  elsif p_source='comment' and existing.source='direct' then raise exception 'delivery_in_flight_retry';
  else return to_jsonb(existing);end if;
 end if;
 if p_source='comment' then perform 1 from app.queue where account_id=p_account_id and contact_id=p_contact_id and idempotency_key like 'greeting:%' and status in ('pending','sending') for update;end if;
 insert into app.flow_runs(account_id,contact_id,revision_id,source,source_id,state,status)
 values(p_account_id,p_contact_id,p_revision_id,p_source,p_source_id,p_state,p_state->>'status')
 on conflict(account_id,contact_id,source,source_id) do nothing returning * into result;
 if result.id is null then select * into result from app.flow_runs where account_id=p_account_id and contact_id=p_contact_id and source=p_source and source_id=p_source_id;end if;
 if p_source='direct' then update app.contacts set greeted_at=coalesce(greeted_at,now()) where id=p_contact_id;end if;
 if p_source='comment' and exists(select 1 from app.queue where account_id=p_account_id and contact_id=p_contact_id and idempotency_key like 'greeting:%' and status='sending') then raise exception 'legacy_greeting_in_flight_retry';end if;
 if p_source='comment' then update app.queue set status='skipped',last_error='campaign_took_ownership' where account_id=p_account_id and contact_id=p_contact_id and idempotency_key like 'greeting:%' and status='pending';end if;
 return to_jsonb(result);
end $$;

create function app.advance_flow_v2(p_account_id uuid,p_run_id uuid,p_expected_version integer,p_transition_key text,p_state jsonb,p_outbox jsonb default null) returns boolean language plpgsql set search_path='' as $$
declare r app.flow_runs; auto uuid;
begin
 select * into r from app.flow_runs where id=p_run_id and account_id=p_account_id for update;
 if not found or r.version<>p_expected_version or r.status in ('completed','cancelled') then return false;end if;
 if r.status='sending' and p_state->>'status'='wait_timer' then
  perform 1 from app.queue where run_id=r.id and status in ('pending','sending') for update;
  if exists(select 1 from app.queue where run_id=r.id and status='sending') then return false;end if;
  update app.queue set status='skipped',last_error='newer_inbound_activity' where run_id=r.id and status='pending';
 end if;
 insert into app.flow_transitions(account_id,run_id,transition_key,node_id,kind) values(p_account_id,p_run_id,p_transition_key,r.state->>'nodeId',split_part(p_transition_key,':',1)) on conflict do nothing;
 if not found then return false;end if;
 if p_outbox is not null then
  select automation_id into auto from app.flow_revisions where id=r.revision_id;
  insert into app.queue(account_id,contact_id,automation_id,event_id,delivery_type,payload,idempotency_key,run_id,node_id)
  values(p_account_id,r.contact_id,auto,nullif(p_outbox->>'event_id','')::uuid,p_outbox->>'delivery_type',p_outbox->'payload','v2:'||p_run_id||':'||p_transition_key,p_run_id,r.state->>'nodeId') on conflict(idempotency_key) do nothing;
 end if;
 update app.flow_runs set state=p_state,version=version+1,status=p_state->>'status',due_at=nullif(p_state->>'dueAt','')::timestamptz,updated_at=now() where id=p_run_id;
 return true;
end $$;

create function app.confirm_flow_delivery(p_queue_id uuid,p_outcome text,p_provider_id text default null) returns uuid language plpgsql set search_path='' as $$
declare q app.queue; r app.flow_runs; next_state jsonb;
begin
 select * into q from app.queue where id=p_queue_id;
 if not found or q.status<>'sending' or q.run_id is null then return null;end if;
 select * into r from app.flow_runs where id=q.run_id and account_id=q.account_id for update;
 select * into q from app.queue where id=p_queue_id for update;
 if q.status<>'sending' then return null;end if;
 if p_outcome not in ('confirmed','rejected','uncertain') then raise exception 'invalid outcome';end if;
 update app.queue set status=case when p_outcome='confirmed' then 'sent' else 'failed' end,sent_at=case when p_outcome='confirmed' then now() else null end,attempts=attempts+1,last_error=case when p_outcome='confirmed' then null else p_outcome end,payload=payload||jsonb_build_object('provider_message_id',p_provider_id) where id=q.id;
 if r.status<>'sending' then return null;end if;
 next_state=r.state;
 if p_outcome='confirmed' then
  next_state=(next_state-'pending')||(r.state->'pending')||jsonb_build_object('status',coalesce(r.state#>>'{pending,status}','running'));
  if next_state->>'status' in ('awaiting_consent','awaiting_action') and r.state->'bufferedInput' is not null then
   next_state=(next_state-'bufferedInput')||jsonb_build_object('status','running','nodeId',coalesce(nullif(next_state->'retryFollowId','null'::jsonb),next_state->'buttonTargets'->split_part(r.state#>>'{bufferedInput,text}',':',4),next_state->'nodeId'),'retryFollowId',null);
  end if;
  if next_state->>'status'='awaiting_consent' and next_state#>>'{context,consent}'='true' then next_state=jsonb_set(next_state,'{status}','"running"');end if;
  next_state=next_state-'bufferedInput';
 else next_state=next_state||jsonb_build_object('status','paused','pauseReason',p_outcome);end if;
 insert into app.flow_transitions(account_id,run_id,transition_key,node_id,kind) values(r.account_id,r.id,'delivery:'||q.id,q.node_id,case when p_outcome='confirmed' then 'sent_'||q.delivery_type else p_outcome end) on conflict do nothing;
 update app.flow_runs set state=next_state,status=next_state->>'status',version=version+1,updated_at=now() where id=r.id;
 return r.id;
end $$;

alter table app.flow_revisions enable row level security;
alter table app.flow_runs enable row level security;
alter table app.flow_transitions enable row level security;
revoke all on app.flow_revisions,app.flow_runs,app.flow_transitions from public,anon,authenticated;
grant select,insert on app.flow_revisions to service_role;grant all on app.flow_runs,app.flow_transitions to service_role;
revoke all on function app.publish_flow_v2(uuid,uuid,jsonb,jsonb),app.start_flow_v2(uuid,uuid,uuid,text,text,jsonb),app.advance_flow_v2(uuid,uuid,integer,text,jsonb,jsonb),app.confirm_flow_delivery(uuid,text,text) from public,anon,authenticated;
grant execute on function app.publish_flow_v2(uuid,uuid,jsonb,jsonb),app.start_flow_v2(uuid,uuid,uuid,text,text,jsonb),app.advance_flow_v2(uuid,uuid,integer,text,jsonb,jsonb),app.confirm_flow_delivery(uuid,text,text) to service_role;

create function app.reject_revision_mutation() returns trigger language plpgsql set search_path='' as $$ begin raise exception 'published revisions are immutable';end $$;
create trigger immutable_flow_revision before update or delete on app.flow_revisions for each row execute function app.reject_revision_mutation();
revoke all on function app.reject_revision_mutation() from public,anon,authenticated;

create function app.enqueue_legacy_greeting(p_account_id uuid,p_contact_id uuid,p_event_id uuid,p_recipient text) returns boolean language plpgsql set search_path='' as $$
declare c app.contacts; message text;
begin
 select * into c from app.contacts where id=p_contact_id and account_id=p_account_id for update;
 if not found or c.greeted_at is not null or c.last_automation_id is not null or exists(select 1 from app.flow_runs where account_id=p_account_id and contact_id=p_contact_id and status not in ('completed','cancelled')) then return false;end if;
 select g.message into message from app.greetings g where g.account_id=p_account_id and g.enabled;
 if message is null or length(trim(message))=0 then return false;end if;
 insert into app.queue(account_id,contact_id,event_id,delivery_type,payload,idempotency_key) values(p_account_id,p_contact_id,p_event_id,'message',jsonb_build_object('recipient_id',p_recipient,'message',message),'greeting:'||p_account_id||':'||p_contact_id) on conflict do nothing;
 if not found then return false;end if;
 update app.contacts set greeted_at=now() where id=p_contact_id;return true;
end $$;
revoke all on function app.enqueue_legacy_greeting(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function app.enqueue_legacy_greeting(uuid,uuid,uuid,text) to service_role;

create function app.cancel_paused_flow(p_account_id uuid,p_run_id uuid) returns boolean language plpgsql set search_path='' as $$
begin
 perform 1 from app.flow_runs where id=p_run_id and account_id=p_account_id and status='paused' for update;
 if not found then return false;end if;
 update app.queue set status='skipped',last_error='operator_cancelled' where run_id=p_run_id and status='pending';
 update app.flow_runs set status='cancelled',state=state||jsonb_build_object('status','cancelled'),version=version+1,updated_at=now() where id=p_run_id;return true;
end $$;
revoke all on function app.cancel_paused_flow(uuid,uuid) from public,anon,authenticated;
grant execute on function app.cancel_paused_flow(uuid,uuid) to service_role;
notify pgrst, 'reload schema';
