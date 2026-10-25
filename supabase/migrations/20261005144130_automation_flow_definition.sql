-- Keep the editable graph separate from the version currently driving sends.
-- Null published graphs continue to run through the legacy automation columns.
alter table app.automations
  add column if not exists flow_definition jsonb,
  add column if not exists published_flow_definition jsonb;
