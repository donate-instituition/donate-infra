# donate-infra

Local infrastructure for the Donate project.

## Services

### RabbitMQ

RabbitMQ is used by `donate-server` to publish background jobs and by
`donate-workers` to consume them.

Start:

```bash
cp .env.example .env
docker compose up -d
```

Stop:

```bash
docker compose down
```

Management UI:

```text
http://localhost:15672
```

Default local credentials:

```text
user: donate
pass: donate
```

Connection URL for local services:

```env
RABBITMQ_URL=amqp://donate:donate@localhost:5672
```

#### Job queues

`donate-server` publishes four job types; `donate-workers` consumes all four
via `WorkerRunnerService` (`donate-workers/src/core/worker-runner.service.ts`)
— exponential backoff on failure (`QUEUE_RETRY_*`/`EMAIL_RETRY_*` below),
then a dead-letter queue once `maxAttempts` is exhausted. Which job type a
given `donate-workers` process handles is selected by `WORKER_NAME` — run
one process per job type (see the `start:*` npm scripts in
`donate-workers/package.json`).

| Job | Queue | DLQ | Business logic lives in |
|---|---|---|---|
| `email.send` | `email.send` | `email.send.dlq` | `donate-workers` |
| `stripe.webhook` | `stripe.webhook` | `stripe.webhook.dlq` | `donate-workers` |
| `receipt.generate` | `receipt.generate` | `receipt.generate.dlq` | `donate-workers` |
| `notification.push` | `notification.push` | `notification.push.dlq` | `donate-workers` |

The other three used to be self-consumed inside `donate-server` with a raw
`nack(message, false, true)` on any failure — an unconditional, un-backed-off
requeue loop with no DLQ. They now go through the same
backoff-then-DLQ machinery `email.send` already had.

Retry/DLQ queues are declared at runtime by `RabbitMqQueueService`
(`assertRetryQueue`/`assertWorkQueue`), not by `docker-compose.yml` — nothing
to configure here beyond making sure `RABBITMQ_RETRY_EXCHANGE`/
`RABBITMQ_DLX_EXCHANGE` match between `donate-server` and `donate-workers`
(both default to `donate.retry`/`donate.dlx`).

Because `stripe.webhook` and `receipt.generate` moved their processing to
`donate-workers`, that repo now needs its own MongoDB connection (same
database as `donate-server`), plus Stripe/S3/Firebase credentials — see
`donate-workers env` below.

### Mailpit

Mailpit is used as the local SMTP server for email workers. It captures emails
instead of sending them to real recipients.

SMTP endpoint:

```text
localhost:1025
```

Inbox UI:

```text
http://localhost:8025
```

### Redis

Redis is used by `donate-server` as the shared cache and coordination layer:
campaign/feed cache, query caching, rate limiting counters, temporary
sessions/tokens, verification codes, idempotency keys, and distributed locks.
`donate-workers` also uses it (`IDEMPOTENCY_PROVIDER=redis`) so a job's
"already completed" marker survives worker restarts and is shared across
multiple worker replicas.

Connection URL for local services:

```env
REDIS_URL=redis://:donate@localhost:6379
```

`--maxmemory-policy allkeys-lru` is set so the container never runs out of
memory in dev: least-recently-used keys are evicted once `--maxmemory` is hit.
That's the right tradeoff for cache/session data, but it means any use case
that must never lose a key before its TTL (e.g. an in-progress distributed
lock) shares eviction risk with everything else in this instance. That's
acceptable for local development; revisit if a use case needs stronger
guarantees in production.

## donate-workers env

```env
QUEUE_PROVIDER=rabbitmq
RABBITMQ_URL=amqp://donate:donate@localhost:5672
RABBITMQ_EXCHANGE=donate.jobs
RABBITMQ_RETRY_EXCHANGE=donate.retry
RABBITMQ_DLX_EXCHANGE=donate.dlx
EMAIL_PROVIDER=smtp
SMTP_HOST=localhost
SMTP_PORT=1025
SMTP_SECURE=false
SMTP_USER=
SMTP_PASS=

# Idempotency store (survives restarts, shared across replicas)
IDEMPOTENCY_PROVIDER=redis
REDIS_URL=redis://:donate@localhost:6379

# Must point at the SAME database donate-server uses — stripe-webhook and
# receipt-generate read/write donate-server's own collections directly.
MONGODB_CLUSTER_URI=mongodb://localhost:27017
MONGODB_DATABASE=test

# Only used to sign/verify the receipt PDF download token — must match
# donate-server's JWT_SECRET exactly, but donate-workers has no auth
# surface of its own.
JWT_SECRET=change-me

STRIPE_SECRET_KEY=
FIREBASE_PROJECT_ID=
FIREBASE_CLIENT_EMAIL=
FIREBASE_PRIVATE_KEY=
```

See `donate-workers/.env.example` for the full list (object storage, the
donation-receipt email template's branding vars, and the shared
`QUEUE_RETRY_*` policy applied to `stripe.webhook`/`receipt.generate`/
`notification.push`).

`OBJECT_STORAGE_DRIVER=local` (the default) writes the generated receipt PDF
to `<cwd>/storage/<key>` on whichever machine runs `donate-workers` —
`donate-server`'s download endpoint reads from its own `<cwd>/storage`, so
local mode only works if both processes share that path (e.g. a bind-mounted
volume). Use `OBJECT_STORAGE_DRIVER=s3` to sidestep this in anything beyond
single-machine local dev.

## donate-server env

```env
RABBITMQ_URL=amqp://donate:donate@localhost:5672
RABBITMQ_EXCHANGE=donate.jobs
REDIS_URL=redis://:donate@localhost:6379
```

## Notes

This repository owns shared local infrastructure. Application code stays in
`donate-server`, `donate-workers`, and `app`.

## Production on AWS

Do not use this `docker-compose.yml` as the production RabbitMQ deployment. The
compose file is only the local development version of the shared infrastructure.

### Recommended: Amazon MQ for RabbitMQ

For a production AWS deployment while keeping RabbitMQ, use Amazon MQ for
RabbitMQ.

Amazon MQ manages:

- RabbitMQ broker lifecycle
- durable storage
- TLS endpoint
- users/passwords
- monitoring hooks
- backups/maintenance
- multi-AZ high availability, when enabled

Email delivery in production should use a real SMTP provider or AWS SES SMTP.
For example:

```env
EMAIL_PROVIDER=smtp
SMTP_HOST=email-smtp.us-east-1.amazonaws.com
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=your-smtp-user
SMTP_PASS=your-smtp-password
EMAIL_FROM=no-reply@your-domain.com
```

Application code does not need to change. Only the environment variables change:

```env
QUEUE_PROVIDER=rabbitmq
RABBITMQ_URL=amqps://user:password@broker-id.mq.region.amazonaws.com:5671
RABBITMQ_EXCHANGE=donate.jobs
RABBITMQ_RETRY_EXCHANGE=donate.retry
RABBITMQ_DLX_EXCHANGE=donate.dlx
```

Use `amqps://` and port `5671` for TLS.

Recommended AWS setup:

1. Create an Amazon MQ RabbitMQ broker.
2. Place it inside the same VPC as `donate-server` and `donate-workers`.
3. Restrict the broker security group to only the application services.
4. Store `RABBITMQ_URL` in AWS Secrets Manager or SSM Parameter Store.
5. Deploy `donate-server` and `donate-workers` on ECS/Fargate, EC2, or another
   compute platform.
6. Configure both services with the same RabbitMQ URL and exchange names.
7. Monitor queues, retries, and DLQs through Amazon MQ/CloudWatch.

### Alternative: Amazon SQS

If the project chooses a more AWS-native queue later, Amazon SQS is also a good
fit for background jobs. SQS has managed DLQs, visibility timeout, and low
operational overhead.

Using SQS would require a different queue adapter in `donate-workers`, but the
worker logic should remain the same because workers depend on the `QueuePort`
abstraction.

Example future config:

```env
QUEUE_PROVIDER=sqs
AWS_REGION=us-east-1
EMAIL_QUEUE_NAME=email.send
EMAIL_DLQ_NAME=email.send.dlq
```

### Production rule of thumb

- Local development: Docker Compose in this repository.
- Production with RabbitMQ: Amazon MQ for RabbitMQ.
- Production fully AWS-native: SQS with DLQ.

## Production Redis: Upstash Redis (Free tier)

Do not use this `docker-compose.yml` Redis container in production either.
For production, `donate-server` points at a managed
[Upstash Redis](https://upstash.com/) database instead.

Upstash speaks the standard Redis protocol (in addition to a separate REST
API meant for edge/serverless callers), so `donate-server` does not need a
different client or code path for local vs. production. The `redis`
(node-redis) client connects to either one from the same `REDIS_URL`
variable — only the URL changes, exactly like the `amqp://` → `amqps://`
switch for RabbitMQ above:

```env
# Local (Docker, plaintext)
REDIS_URL=redis://:donate@localhost:6379

# Production (Upstash, TLS — note the "rediss://" scheme)
REDIS_URL=rediss://default:<password>@<endpoint>.upstash.io:6379
```

Recommended setup:

1. Create a Redis database in the Upstash console (regional, in the same AWS
   region as `donate-server` to keep latency low), on the Free plan.
2. Copy the "Redis" (`rediss://`) connection string from the database
   details page — not the REST URL/token pair, which is only needed by the
   HTTP-based `@upstash/redis` client for edge/serverless runtimes.
3. Store `REDIS_URL` in AWS Secrets Manager or SSM Parameter Store.
4. Set `REDIS_URL` on the `donate-server` deployment. No other config or
   code change is required.
5. The Free plan caps storage, bandwidth, and command throughput — check the
   current limits on the Upstash pricing page before relying on it for
   anything beyond cache/rate-limit/session traffic, and upgrade the plan if
   the project outgrows it.

Application code does not need to change between environments beyond the
`REDIS_URL` value.
