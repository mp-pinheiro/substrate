gate *ARGS:
    .substrate/gate.sh {{ARGS}}

engine:
    go build -o build/substrate-engine ./cmd/substrate-engine

test-engine:
    go build ./... && go vet ./... && go test ./internal/...
    bash test/ab-hooks-test.sh
    bash test/golden-ledger-test.sh
    bash test/engine-rollback-test.sh
