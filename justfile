export SUBSTRATE_VENDOR_FROM_WORKTREE := "1"

gate *ARGS:
    go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" -o build/substrate-engine ./cmd/substrate-engine && PATH="{{justfile_directory()}}/build:$$PATH" substrate-engine gate {{ARGS}}

battery *ARGS:
    bash test/run.sh {{ARGS}}

engine:
    go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" -o build/substrate-engine ./cmd/substrate-engine

test-engine:
    go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" ./... && go vet ./... && go test ./internal/...
    bash test/ab-hooks-test.sh
    bash test/golden-ledger-test.sh
    bash test/engine-rollback-test.sh


generate-registry:
    go run ./cmd/generate-registry > internal/gate/registry_gen.go