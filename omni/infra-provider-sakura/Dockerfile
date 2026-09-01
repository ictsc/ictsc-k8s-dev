# syntax=docker/dockerfile:1
FROM golang:1.27-alpine AS build
WORKDIR /src
RUN apk add --no-cache ca-certificates git
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/omni-infra-provider-sakura ./cmd/omni-infra-provider-sakura

FROM alpine:3.23
RUN apk add --no-cache ca-certificates xorriso
COPY --from=build /out/omni-infra-provider-sakura /usr/local/bin/omni-infra-provider-sakura
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/omni-infra-provider-sakura"]
