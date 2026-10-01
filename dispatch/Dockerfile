FROM golang:1.24

WORKDIR /go/src/app

# go.mod and go.sum are committed, so the dependency graph is pinned. The
# previous build ran "go mod init && go get" at image build time, which
# resolved whatever the latest matching versions happened to be on that
# day. Two builds a week apart could produce different binaries from an
# identical Dockerfile.
COPY go.mod go.sum ./
RUN go mod download

COPY *.go .

RUN go build -o dispatch .

# Run the unprivileged user the base image already provides, rather than
# root. Nothing here needs write access or a listening port.
USER 65534:65534

CMD ["/go/src/app/dispatch"]
