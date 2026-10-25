-- Supabase Pro runs the delayed delivery queue every minute independently of Vercel plan limits.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
-- Drain due automation deliveries once per minute using Supabase Pro Cron.
-- URL and bearer secret are stored separately in Supabase Vault.
select cron.schedule(
  'social-selling-queue-drain',
  '* * * * *',
  $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'social_selling_queue_url') || '/api/internal/queue/drain',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'social_selling_queue_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

