FROM 84codes/crystal:latest-alpine AS builder

WORKDIR /app

COPY shard.yml /app/
RUN shards

COPY *.cr /app/
RUN shards build mutating_webhooks --static --release

FROM scratch

COPY --from=builder /app/bin/mutating_webhooks /

CMD ["/mutating_webhooks"]
