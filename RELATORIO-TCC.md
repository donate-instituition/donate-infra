# EloDoar — Relatório técnico do sistema (referência para a monografia)

> Documento de apoio à escrita do TCC, gerado a partir de uma auditoria do
> código-fonte real em 2026-08-11 (não a partir da documentação antiga dos
> repositórios individuais, que estava desatualizada em vários pontos —
> ver seção "Divergências encontradas" no fim). Este relatório cobre a
> visão **geral do sistema** (por isso vive em `donate-infra`, o
> repositório que amarra os outros três); cada repositório tem também o
> seu próprio `RELATORIO.md` com o detalhe do que está implementado nele
> especificamente. Os arquivos `.md` que já existiam em cada repositório
> (`app/project/overview.md`, `donate-workers/README.md`,
> `donate-server/entidades.md` etc.) **não** foram alterados, por pedido
> explícito.

## 1. Visão geral

EloDoar é uma plataforma de doações que conecta doadores pessoa física a
instituições beneficentes verificadas, com campanhas de arrecadação,
pagamento via Stripe, emissão de recibo fiscal, rede social leve
(posts/curtidas/comentários/seguir), chat em tempo real entre doador e
instituição, e um sistema de notificações (push + e-mail) configurável por
categoria.

O projeto é dividido em **4 repositórios independentes**, cada um com seu
próprio histórico git:

| Repositório | Papel | Stack |
|---|---|---|
| `donate-server` | API principal (REST + WebSocket), fonte da verdade dos dados | NestJS, MongoDB (Mongoose), Redis, RabbitMQ, Socket.IO |
| `donate-workers` | Processamento assíncrono (filas + cron) | NestJS (application context, sem HTTP), MongoDB, Redis, RabbitMQ, Firebase Admin, Stripe |
| `app` | Aplicativo móvel do doador/instituição/admin | Expo Router v6 (SDK 54), React Native 0.81, Zustand, TanStack Query, TypeScript |
| `donate-infra` | Infraestrutura local (Docker Compose) | RabbitMQ, Redis, Mailpit |

**Por que dois backends (`donate-server` + `donate-workers`)?** `donate-server`
atende requisições HTTP/WebSocket síncronas. Tudo que é assíncrono ou pode
demorar (processar webhook do Stripe, gerar PDF de recibo, enviar push,
enviar e-mail, o resumo semanal por e-mail) foi migrado para
`donate-workers`, que consome filas RabbitMQ com retry exponencial e
dead-letter queue (DLQ) por tipo de job, evitando que uma falha externa
(Stripe fora do ar, provedor de e-mail lento) trave a API principal.

## 2. Modelo de dados (25 domínios no `donate-server`)

Coleções MongoDB, sem chaves estrangeiras impostas pelo banco (relações são
por `ObjectId` referenciado manualmente no código):

`users`, `institutions`, `institution_staff_memberships`, `categories`,
`campaigns`, `donations`, `donation_status_history`, `payments`,
`delivery_proofs`, `tax_receipts`, `tracking_events`, `posts`,
`post_comments`, `post_reactions`, `conversations`, `messages`,
`notifications`, `follows`, `reports`, `audit_logs`, `app_settings`,
`support_faqs`, `terms`, `error_logs`.

### Entidades centrais (campos principais)

**User** — `type` (PERSON), `roles: [{name, grantedAt, grantedBy}]`
(multi-papel, com trilha de auditoria — **não** é um campo único, um
usuário pode acumular DONOR + INSTITUTION_STAFF + PLATFORM_ADMIN
simultaneamente), `fullName`, `email` (único), `phone?`, `cpf?`,
`passwordHash`, `googleId?` (único, esparso — vínculo com Google Sign-In),
`birthDate?`, `profilePhotoUrl?`, `bio?`, `pushTokens[]`, `status`
(PENDING_VERIFICATION/ACTIVE/SUSPENDED/DELETED), `isVerified`,
`termsAccepted`/`acceptedTermsVersion`/`termsAcceptedAt`, `settings`
(`privateProfile`, `allowMessagesFrom`, `preferredRole`,
`notifications: {donations, campaigns, conversations,
emailDigestEnabled}` — todos booleanos independentes), `stats` (total
doado, doações, seguindo/seguidores).

**Institution** — `legalName`, `displayName`, `cnpj` (único), `email`,
`phone?`, `description?`, `categoryIds[]`, `logoUrl?`, `coverPhotoUrl?`,
`website?`, `status` (PENDING_APPROVAL/ACTIVE/…), `verification`
(`isVerified`, `verifiedAt`, `verifiedByUserId`), `address`,
`acceptedDonationTypes[]`, `pixKey?`, `stripeConnectAccountId?`,
`stripeConnect` (status detalhado da conta Stripe Connect: cobranças
habilitadas, pendências, modo teste/produção), `acceptsRecurringDonations`,
`taxReceiptEnabled`, `stats` (seguidores, campanhas, doações recebidas,
valor arrecadado, posts).

**Campaign** — `institutionId`, `createdByUserId`, `title`, `description?`,
`bannerUrl?`, `status` (DRAFT/IN_REVIEW/PUBLISHED/PAUSED/FINISHED/CANCELED),
`donationTypes[]`, `acceptedItems[]`, `goal: {moneyTarget, itemsTarget}`,
`progress: {moneyRaised, itemsRaised}`, `visibility`, `startAt?`, `endAt?`,
`address?`, `tags[]`, `stats` (seguidores, curtidas, comentários,
compartilhamentos, doações, posts).

**Conversation** / **Message** — chat real, não simulado: `Conversation`
guarda `type`, `participantIds[]`, `institutionId?`, `campaignId?`,
`lastMessageAt?`; `Message` (coleção própria, reaproveitada pelo domínio de
conversas) guarda `conversationId`, `senderUserId`, `content?`,
`messageType`, `attachments[]`, `readBy: [{userId, readAt}]`. Entrega em
tempo real via `ConversationsGateway` (Socket.IO, namespace `/chat`,
autenticação por JWT na conexão, uma "room" por usuário
`user:<id>`) — eventos `conversationUpdated`, `messageCreated`,
`unreadUpdated`.

**Notification** — `userId`, `type` (enum: `DONATION_STATUS_UPDATED`,
`NEW_FOLLOWER`, `NEW_MESSAGE`, `CAMPAIGN_UPDATE`,
`CAMPAIGN_GOAL_REACHED`), `title`, `body`, `data?` (payload livre),
`readAt?`.

Duas fontes documentam o modelo de dados dentro do próprio
`donate-server` (`entidades.md`, `docs/diagrama-entidade-relacionamento.md`)
mas estão desatualizadas em relação ao código atual — ver seção 7.

## 3. Superfície de API (`donate-server`, prefixo implícito por domínio)

24 controllers REST + 1 gateway WebSocket. Autenticação via JWT Bearer
(access token de vida curta + refresh token); rotas marcadas `@Public()`
não exigem token; rotas com `@Roles(PLATFORM_ADMIN)` (ou
`INSTITUTION_STAFF`) exigem o papel correspondente entre os `roles` do
usuário autenticado.

- **auth** — login e senha, **Google Sign-In** (`POST auth/google` +
  `POST auth/google/onboarding` para completar cadastro de usuários novos),
  registro, ativação de conta por e-mail, esqueci minha senha (código por
  e-mail), refresh de sessão, `PATCH auth/me/settings` (papel preferido
  **e** preferências de notificação por categoria).
- **users** — CRUD, registro/remoção de push token, detalhe administrativo
  de usuário (`PLATFORM_ADMIN`).
- **institutions** — CRUD público de leitura, fila de aprovação
  administrativa (`admin/pending`, `approve`, `reject`), configuração de
  conta Stripe Connect.
- **institution-staff-memberships** — vínculo funcionário↔instituição,
  convite, papel (OWNER/staff), listagem de equipe.
- **campaigns** — CRUD, publicação, upload de imagem, curtir/comentar/
  compartilhar.
- **donations** — criação, histórico do doador e da instituição.
- **payments** — dois controllers (`payments` e `stripe`): criação/
  confirmação de PaymentIntent, cancelamento de assinatura recorrente,
  config pública da Stripe, **webhook do Stripe** (o único ponto de
  verdade sobre o status real do pagamento).
- **tax-receipts** — CRUD + download de PDF assinado (token HMAC).
- **conversations** / **messages** — chat.
- **notifications** — inbox in-app, marcar como lida.
- **posts** / **post-comments** / **post-reactions** — rede social leve
  (feed, curtidas, comentários, compartilhamento).
- **follows** — seguir usuário/instituição/campanha.
- **categories**, **delivery-proofs**, **donation-status-history**,
  **tracking-events**, **reports**, **audit-logs**, **app-settings**
  (config dinâmica só-admin), **support-faqs** (FAQ de suporte),
  **terms** (termos de uso versionados, aceite).

Não existe um módulo "admin" único — capacidades administrativas estão
distribuídas nos controllers de domínio, protegidas por
`@Roles(PLATFORM_ADMIN)`.

## 4. Processamento assíncrono (`donate-workers`)

5 workers, cada um pode rodar como processo Node dedicado
(`WORKER_NAME=<nome>`) ou todos juntos num só processo local
(`WORKER_NAME=all`, o padrão de `npm run start` — ver seção "Trabalho
recente" abaixo):

1. **stripe-webhook** — consome a fila `stripe.webhook`. Processa cada
   evento do Stripe: atualiza `Payment`/`Donation`, incrementa
   `progress.moneyRaised` e `stats.donationsCount` da campanha, invalida
   cache Redis da campanha/instituição, detecta quando uma campanha
   **cruza a meta de arrecadação** (comparação antes/depois do incremento,
   não só "está acima", para não disparar de novo em cada doação
   seguinte) e nesse caso notifica quem segue a campanha e a instituição
   dona. Publica em seguida o job de geração de recibo.
2. **receipt-generate** — consome `receipt.generate`. Gera o PDF do recibo
   fiscal e o registro correspondente, então publica a notificação push
   "doação confirmada" e o e-mail de recibo — ambos condicionados à
   preferência `notifications.donations` do doador.
3. **notification-push** — consome `notification.push`. Envia via Firebase
   Admin (FCM) para os tokens de push ativos do usuário. Desde a última
   rodada de trabalho, o envio é filtrado **por categoria** — o tipo da
   notificação (`DONATION_STATUS_UPDATED`/`NEW_MESSAGE`/
   `CAMPAIGN_GOAL_REACHED`) é mapeado para o campo de preferência
   correspondente (`donations`/`conversations`/`campaigns`) em vez de um
   único interruptor global "push ligado/desligado".
4. **notification-digest** — não consome fila, é agendado por cron
   (`@nestjs/schedule`, expressão configurável, padrão toda segunda 9h).
   Para cada usuário com `notifications.emailDigestEnabled = true`, soma
   as doações dos últimos 7 dias e envia um e-mail-resumo (mesmo template
   visual do recibo); usuários sem atividade na semana não recebem nada.
5. **email** — consome `email.send`. Provedores plugáveis (SMTP/Resend/
   console, este último para dev local via Mailpit).

Todas as filas têm **retry exponencial com jitter** e uma **dead-letter
queue** própria — depois de esgotadas as tentativas, a mensagem vai para
`<fila>.dlq` em vez de ser descartada.

## 5. Cache (Redis)

Usado para: cache-aside de feed/campanhas/perfil de instituição (com
invalidação por versão de lista), rate limiting (substituindo memória
local, que não escala entre instâncias), armazenamento de sessão/código de
verificação (esqueci minha senha), idempotência de requisições mutáveis
(header `Idempotency-Key`), e locks distribuídos onde necessário. Em
desenvolvimento roda local via Docker (`donate-infra`); a configuração já
está pronta para apontar para Upstash Redis em produção sem mudança de
código, só de variável de ambiente.

## 6. Funcionalidades do app (visão por área)

Confirmado por auditoria de código em 2026-08-11: **nenhum serviço do app
usa dados mock/em memória** — todos os 13 serviços em `src/services/`
conversam com a API real (contradiz a documentação antiga do repositório,
que descrevia doações, chat e campanhas como simulados).

### Autenticação e conta
- Login por e-mail/senha e **Sign in with Google** (fluxo completo:
  verificação do ID token no backend, vínculo automático se o e-mail já
  existir, onboarding de duas telas — escolher Doador/Instituição, depois
  CPF/data de nascimento/telefone/senha opcional/termos — para contas
  novas antes de qualquer sessão ser emitida).
- Cadastro tradicional, ativação de conta por link de e-mail, recuperação
  de senha por código.
- Foto de perfil: usa a foto do Google como preenchimento automático **só
  na primeira vez** (nunca sobrescreve uma foto que o usuário já
  escolheu manualmente), exibida em todos os pontos do app onde o avatar
  do usuário aparece.
- Preferências de notificação (tela antes decorativa, hoje persistida de
  verdade): 4 categorias independentes — Doações, Campanhas, Conversas,
  Resumo por e-mail — com toggle otimista e reversão em caso de erro.

### Navegação por papel
Doador, funcionário de instituição e administrador da plataforma têm
**layouts de abas distintos** (não é mais um único conjunto de 5 telas
compartilhado entre papéis, como em versões anteriores):
- **Doador**: início, campanhas, doações, mensagens, perfil.
- **Instituição**: início, campanhas, **criar campanha**, mensagens,
  perfil.
- **Admin**: início, usuários, instituições, auditoria, perfil.

### Doações e pagamento
- Stripe PaymentSheet real no app (`@stripe/stripe-react-native`),
  doação única ou recorrente (assinatura mensal, com cancelamento).
- Status da doação é sempre ditado pelo webhook do Stripe processado no
  backend, nunca otimista no cliente.
- Recibo fiscal em PDF gerado de forma assíncrona após confirmação do
  pagamento, com link de download assinado.

### Campanhas e instituições
- Busca/listagem com filtro por categoria, detalhe de campanha (progresso,
  itens necessários, descrição), detalhe de instituição (verificação,
  campanhas ativas), criação de campanha (fluxo da instituição).

### Rede social
- Feed de posts, curtir, comentar, compartilhar; seguir
  usuário/instituição/campanha.

### Chat
- Conversas em tempo real doador↔instituição via WebSocket (Socket.IO),
  não mock — mensagens persistidas, indicador de não lidas, entrega ao
  vivo.

### Notificações push
- Registro/renovação de token FCM via `@react-native-firebase/messaging` +
  `expo-notifications`, tratamento de mensagem em primeiro/segundo plano —
  pipeline completo e funcional, não um placeholder.

### Administração (app)
- Telas de usuários, instituições e auditoria para o papel
  `platform-admin`, consumindo os mesmos endpoints `@Roles(PLATFORM_ADMIN)`
  do backend.

## 7. Trabalho mais recente (sessão atual)

Nesta rodada de desenvolvimento, além de correções pontuais, foram
entregues três frentes:

1. **Login com Google** — de ponta a ponta (backend + app), incluindo
   onboarding de dois passos para contas novas e uso da foto do Google
   como avatar padrão (nunca sobrescrevendo escolha do usuário).
2. **Preferências de notificação reais** — a tela que antes só alterava
   estado local em memória agora persiste no backend; isso motivou
   construir três capacidades que não existiam:
   - Filtragem de push por categoria (antes era um único interruptor
     global).
   - Notificação de **meta de campanha atingida**, com detecção de
     cruzamento de meta (não reenvia a cada doação subsequente) e
     notificação de seguidores da campanha e da instituição.
   - **Resumo semanal por e-mail**, novo worker agendado por cron
     (`@nestjs/schedule`, dependência nova no projeto — não havia
     nenhuma biblioteca de cron antes).
3. **Conveniência operacional** — `WORKER_NAME=all` permite rodar os 5
   workers num único processo (`npm run start`), útil para desenvolvimento
   local sem abrir 5 terminais; em produção cada worker ainda pode ser
   escalado como processo independente via `WORKER_NAME=<nome>`.

## 8. Divergências encontradas entre código e documentação antiga

Para não citar informação errada na monografia, seguem as inconsistências
confirmadas por auditoria direta do código (não da documentação):

- `app/project/overview.md` descreve doações, chat e campanhas como
  serviços "mock" em memória. **Falso hoje** — os 13 serviços do app usam
  API real.
- O mesmo documento descreve push notifications como "NOT IMPLEMENTED".
  **Falso hoje** — pipeline FCM completo e funcional.
- O mesmo documento descreve os 3 papéis de usuário como compartilhando as
  mesmas 5 telas. **Desatualizado** — cada papel tem layout de abas
  próprio hoje (doador/instituição/admin claramente distintos).
- `donate-server/entidades.md` descreve `User.role` como campo único.
  **Desatualizado** — hoje é `roles: []`, multi-papel com trilha de
  auditoria (`grantedAt`/`grantedBy`). Também não cobre os domínios
  `app-settings`, `support-faqs`, `terms` e `error-logs`, todos
  adicionados depois da última atualização do documento.
- `donate-workers/README.md` documenta só o worker de e-mail. Hoje existem
  5 workers (stripe-webhook, receipt-generate, notification-push,
  notification-digest, email).

Esses arquivos **não foram alterados** (por pedido explícito, para manter
este relatório como o único documento novo) — mas se a monografia for
citar algum deles diretamente, vale a pena checar contra o código antes.
