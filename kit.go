package substrate

import "embed"

//go:embed all:bin all:core all:profiles all:skills all:agents VERSION engine.json
var Kit embed.FS
