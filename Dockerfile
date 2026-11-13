FROM swift:6.0-jammy AS builder

WORKDIR /workspace
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build -c release --product sec-dataset-builder

FROM swift:6.0-jammy-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /workspace/.build/release/sec-dataset-builder /usr/local/bin/sec-dataset-builder

ENV OUT_DIR=/tmp/SECTESTFILE-3
ENTRYPOINT ["/usr/local/bin/sec-dataset-builder"]
CMD ["fetch"]

