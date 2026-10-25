-- This gate intentionally defaults to unavailable. A link may only be sent when
-- the account has a Meta-provided follower-check capability and the contact is
-- positively identified as a follower. It must never infer a follow from a tap.
alter table app.instagram_accounts
  add column follower_check_capability text not null default 'unavailable'
  check (follower_check_capability in ('unavailable', 'pending_meta_eligibility', 'available'));

alter table app.contacts
  add column follower_status text not null default 'unknown'
  check (follower_status in ('unknown', 'follower', 'not_follower')),
  add column follower_status_checked_at timestamptz,
  add column follower_status_source text
  check (follower_status_source is null or follower_status_source in ('meta'));

alter table app.automations
  add column requires_follower boolean not null default false,
  add column follower_gate_message text,
  add column follower_gate_confirmation_message text;

create index contacts_follower_status_index
  on app.contacts (account_id, follower_status, follower_status_checked_at desc);