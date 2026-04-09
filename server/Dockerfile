FROM rust:1.88-bookworm AS builder
WORKDIR /app
COPY . .
RUN cargo build --release --bin trio-cloud

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/trio-cloud /usr/local/bin/trio-cloud
ENV PORT=8080
EXPOSE 8080
CMD ["trio-cloud"]
