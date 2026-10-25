create or replace function app.claim_queue_batch(batch_size integer default 4)
returns setof app.queue
language plpgsql
security invoker
set search_path = app, pg_temp
as $$
begin
  return query
  with claimed as (
    select id from app.queue
    where status = 'pending' and scheduled_at <= now()
    order by scheduled_at asc
    limit least(greatest(batch_size, 1), 10)
    for update skip locked
  ), updated as (
    update app.queue q
    set status = 'sending', claimed_at = now()
    from claimed
    where q.id = claimed.id
    returning q.*
  ) select * from updated;
end;
$$;