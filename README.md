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
```

## donate-server env

```env
RABBITMQ_URL=amqp://donate:donate@localhost:5672
RABBITMQ_EXCHANGE=donate.jobs
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
