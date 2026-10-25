alter table app.events add column if not exists processing_claim_id uuid;
alter table app.events add column if not exists processing_claimed_at timestamptz;

create or replace function app.claim_webhook_event(p_event_id uuid, p_claim_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare e app.events;
begin
  select * into e from app.events where id=p_event_id for update;
  if not found then raise exception 'event not found'; end if;
  if e.processing_status='processed' then return jsonb_build_object('status','processed'); end if;
  if e.processing_status='processing' and e.processing_claimed_at > now()-interval '3 minutes'
    then return jsonb_build_object('status','busy'); end if;
  update app.events set processing_status='processing',processing_claim_id=p_claim_id,processing_claimed_at=now() where id=e.id;
  return jsonb_build_object('status','claimed','event',to_jsonb(e));
end $$;

create or replace function app.finish_webhook_event(p_event_id uuid,p_claim_id uuid,p_success boolean)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
  update app.events set processing_status=case when p_success then 'processed' else 'received' end,
    processed_at=case when p_success then now() else null end,
    processing_claim_id=null,processing_claimed_at=null
    where id=p_event_id and processing_status='processing' and processing_claim_id=p_claim_id;
  return found;
end $$;
revoke all on function app.claim_webhook_event(uuid,uuid),app.finish_webhook_event(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function app.claim_webhook_event(uuid,uuid),app.finish_webhook_event(uuid,uuid,boolean) to service_role;
notify pgrst, 'reload schema';

create or replace function app.claim_comment_flow(
  p_account_id uuid,
  p_contact_id uuid,
  p_automation_id uuid,
  p_comment_id text
)
returns boolean
language plpgsql
security invoker
set search_path = app, pg_temp
as $$
declare
  updated_rows integer;
begin
  if p_comment_id is null or length(trim(p_comment_id)) = 0 then
    return false;
  end if;

  update app.contacts
  set last_automation_id = p_automation_id,
      flow_source_comment_id = p_comment_id,
      flow_step = 0,
      flow_completed_at = null
  where id = p_contact_id
    and account_id = p_account_id
    and flow_source_comment_id is distinct from p_comment_id
    and (flow_source_comment_id is null or flow_completed_at is not null);

  get diagnostics updated_rows = row_count;
  if updated_rows > 0 then
    return true;
  end if;

  return exists (
    select 1 from app.contacts
    where id = p_contact_id
      and account_id = p_account_id
      and flow_source_comment_id = p_comment_id
  );
end;
$$;

revoke all on function app.claim_comment_flow(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function app.claim_comment_flow(uuid, uuid, uuid, text) to service_role;
