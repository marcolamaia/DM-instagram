-- OAuth and webhook deliveries can use different Meta account identifiers.
-- The webhook ID is learned only during an isolated validation event.
alter table app.instagram_accounts
  add column if not exists webhook_user_id text;

create unique index if not exists instagram_accounts_webhook_user_id_key
  on app.instagram_accounts (webhook_user_id)
  where webhook_user_id is not null;

-- Each buyer's webhook identifier is learned through its own OAuth/webhook flow.
