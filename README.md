# Social Selling

Aplicacao Next.js de automacoes Instagram, editor visual de fluxos, templates, fila de entregas e analytics. A fonte desta entrega e a arvore principal do Social Selling; a alternativa antiga Foguinho nao foi misturada.

## Instalacao

1. Use Node >=22.13. Execute npm ci.
2. Copie .env.example para .env.local e preencha valores proprios. Gere segredos aleatorios independentes para sessao, OAuth, criptografia e fila. TOKEN_ENCRYPTION_KEY deve seguir o formato exigido em src/lib/token-vault.ts. Nao existe senha administrativa padrao.
3. Crie Supabase independente. Revise e aplique supabase/migrations por ordem cronologica em banco vazio. O schema usado pela aplicacao e app. Nunca importe dados de outras operacoes.
4. ADMIN_EMAIL_ALLOWLIST deve conter seu e-mail e ADMIN_PASSWORD sua senha propria. Configure NEXT_PUBLIC_APP_URL com seu dominio HTTPS.
5. Crie seu proprio app Meta/Instagram, credenciais, callback OAuth e webhook conforme as rotas src/app/api/oauth/instagram/callback e src/app/api/webhook. Permissoes e revisao Meta pertencem ao comprador.
6. Execute npm run dev. Para producao, npm run build e npm start.

META_INTEGRATION_READY vem desativado. Confirme permissao, consentimento e envio em conta de teste propria antes de habilitar. Configure no Vault os segredos social_selling_queue_url e social_selling_queue_secret antes de ativar o agendamento de fila. A migracao de agendamento foi movida para setup/optional-scheduler.sql para impedir chamadas antes da configuracao.

## Personalizacao

Revise marca, textos legais e contato@example.invalid antes de operar. Templates de campanhas de clientes foram excluidos; crie exemplos proprios e configure seu canal autorizado. Nenhum contato, token, conta Instagram ou campanha operacional e incluido.

## Verificacao

Execute npm test, npm run lint e npm run build. Testes locais usam mocks; OAuth, webhooks, fila agendada e envio real exigem os servicos do comprador.

## Privacidade e entrega

Pacote independente, sem contas, bancos, credenciais ou historico da operacao original. Use somente servicos e dados do comprador. Nunca envie arquivos de ambiente ao Git. Exemplos usam dominios invalidos e dados sinteticos.

## Licenca

Software comercial proprietario; consulte LICENSE.txt e o contrato de compra. Dependencias e fontes preservam suas licencas de terceiros.


## Schema privado na Data API

Depois de aplicar as migrations, abra as configuracoes da Data API do seu projeto Supabase e inclua app em Exposed schemas. As migrations mantem anon e authenticated sem acesso ao schema app e concedem acesso somente a service_role, usada exclusivamente no servidor. Nao copie exemplos de GRANT amplo para navegadores. Confira tambem os grants das migrations e teste a conexao do servidor. Referencia: [Using Custom Schemas](https://supabase.com/docs/guides/api/using-custom-schemas).
