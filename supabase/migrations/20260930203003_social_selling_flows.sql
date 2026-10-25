alter table app.automations
  add column conversation_blocks text[] not null default '{}';

alter table app.contacts
  add column flow_step integer not null default 0,
  add column flow_source_comment_id text,
  add column flow_completed_at timestamptz,
  add column greeted_at timestamptz;

create table app.greetings (
  account_id uuid primary key references app.instagram_accounts(id) on delete cascade,
  enabled boolean not null default false,
  message text not null default '',
  updated_at timestamptz not null default now(),
  check (not enabled or length(trim(message)) > 0)
);

alter table app.greetings enable row level security;
grant select, insert, update, delete on app.greetings to service_role;
create index contacts_greeting_index on app.contacts (account_id, greeted_at);
