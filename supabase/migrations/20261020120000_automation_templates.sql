create table app.automation_templates (
 id uuid primary key default gen_random_uuid(),
 account_id uuid not null references app.instagram_accounts(id),
 name text not null check(length(name) between 1 and 120),
 definition jsonb not null,
 created_at timestamptz not null default now()
);
create index automation_templates_account_idx on app.automation_templates(account_id,created_at desc);
alter table app.automation_templates enable row level security;
revoke all on app.automation_templates from public,anon,authenticated;
grant select,insert,update,delete on app.automation_templates to service_role;
