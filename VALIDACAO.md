# Validacao desta entrega

Verificacao local da entrega comercial:
CRM: API 85 testes; interface 16 testes; catalogo 3 testes. Builds de interface e catalogo aprovados. Lint da interface: 0 erros e 36 avisos herdados.
Nucleus: 26 testes, incluindo recursos comerciais sem fotos privadas; renderizacao sintetica de 2 slides aprovada.
Social Selling: 73 testes, incluindo instalacao de todas as migrations principais em banco PGlite vazio, sem registros operacionais; build e lint aprovados.
HTTP local: 6 rotas verificadas com status 200; Social Selling sem Supabase configurado e sem contas conectadas.
Auditoria: exclusao de ambientes, historico original e materiais privados; verificacao de identidades, destinos operacionais, padroes de credencial, IDs de contas embutidos e valores privados conhecidos dos ambientes de origem.
Limites: testes reais de OAuth/Instagram, WhatsApp, banco Supabase remoto, gateways e APIs pagas dependem das contas e configuracao do comprador; nao foram executados. A ativacao das extensoes e do cron Supabase foi separada dos testes de schema em PGlite.
