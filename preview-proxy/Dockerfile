FROM golang:1.27.3-bookworm AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /preview-proxy main.go
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /preview-proxy /preview-proxy
USER 65532:65532
ENTRYPOINT ["/preview-proxy"]
