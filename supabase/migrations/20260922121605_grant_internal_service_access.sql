-- Keep the automation schema private to browser clients while allowing only
-- the server-side Supabase service credential to persist test connections.
revoke all on schema app from anon, authenticated;
revoke all on all tables in schema app from public, anon, authenticated;

grant usage on schema app to service_role;
grant select, insert, update, delete on all tables in schema app to service_role;

alter default privileges in schema app revoke all on tables from public;
alter default privileges in schema app grant select, insert, update, delete on tables to service_role;