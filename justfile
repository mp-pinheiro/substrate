gate *ARGS:
    .substrate/gate.sh {{ARGS}}

engine:
    go build -o build/substrate-engine ./cmd/substrate-engine
