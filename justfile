gate *ARGS:
    .substrate/gate.sh {{ARGS}}

battery *ARGS:
    bash test/run.sh {{ARGS}}

engine:
    go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" -o build/substrate-engine ./cmd/substrate-engine

test-engine:
    go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" ./... && go vet ./... && go test ./internal/...
    bash test/ab-hooks-test.sh
    bash test/golden-ledger-test.sh
    bash test/engine-rollback-test.sh
