// Nested module: keeps the deliberately broken fixtures out of the kit's own
// `go build ./...` package set. Never copied into scratch repos (matrix.sh
// seeds only clean-* files).
module substratefixtures

go 1.22
