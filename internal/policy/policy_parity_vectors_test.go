package policy

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnginePolicyParityProtectPaths(t *testing.T) {
	vectors := []parityVector{
		{name: "benign relative path", guard: "protect-paths", payload: filePayload("src/foo.go")},
		{
			name: "corrupt config blocks write", guard: "protect-paths", payload: filePayload("foo.txt"),
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, "{ not json") },
		},
		{
			name: "corrupt config blocks substrate config write", guard: "protect-paths", payload: filePayload("substrate.json"), want: LevelBlock,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, "{ not json") },
		},
		{
			name: "contracts shape invalid blocks write", guard: "protect-paths", payload: filePayload("foo.txt"),
			setup: func(t *testing.T, root string) {
				writeSubstrateJSON(t, root, `{"contracts":[{"name":123,"regen":"gen","paths":["x"]}]}`)
			},
		},
		{
			name: "symlink write blocked", guard: "protect-paths", payload: filePayload("link.txt"),
			setup: func(t *testing.T, root string) {
				writeRepoFile(t, root, "target.txt", "hello")
				if err := os.Symlink("target.txt", filepath.Join(root, "link.txt")); err != nil {
					t.Fatalf("symlink: %v", err)
				}
			},
		},
		{
			name: "path resolving outside repo blocked", guard: "protect-paths", payload: filePayload("escape/newfile.txt"),
			setup: func(t *testing.T, root string) {
				outside := t.TempDir()
				if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
					t.Fatalf("symlink: %v", err)
				}
			},
		},
		{name: "baseline exact literal blocked", guard: "protect-paths", payload: filePayload("substrate-baseline.json")},
		{name: "baseline lookalike nested blocked", guard: "protect-paths", payload: filePayload("sub/dir/substrate-baseline.json")},
		{name: "substrate config exact asks", guard: "protect-paths", payload: filePayload("substrate.json"), want: LevelAsk},
		{name: "dot-prefixed substrate config asks", guard: "protect-paths", payload: filePayload("./substrate.json"), want: LevelAsk},
		{name: "parent-normalized substrate config asks", guard: "protect-paths", payload: filePayload("sub/../substrate.json"), want: LevelAsk},
		{name: "redundant-normalized substrate config asks", guard: "protect-paths", payload: filePayload("sub/./../substrate.json"), want: LevelAsk},
		{name: "nested substrate config is not canonical", guard: "protect-paths", payload: filePayload("sub/dir/substrate.json"), want: LevelAllow},
		{
			name: "protected_paths raises substrate config to block", guard: "protect-paths", payload: filePayload("substrate.json"), want: LevelBlock,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"protected_paths":["substrate.json"]}`) },
		},
		{name: "dotSubstrate write blocked", guard: "protect-paths", payload: filePayload(".substrate/foo.txt")},
		{name: "CLAUDE.md write asks", guard: "protect-paths", payload: filePayload("CLAUDE.md"), want: LevelAsk},
		{name: "nested CLAUDE.md write asks", guard: "protect-paths", payload: filePayload("claude/CLAUDE.md"), want: LevelAsk},
		{name: "AGENTS.md write asks", guard: "protect-paths", payload: filePayload("data/Lua/AGENTS.md"), want: LevelAsk},
		{name: "CLAUDE.md lookalike allowed", guard: "protect-paths", payload: filePayload("docs/CLAUDE.md.bak"), want: LevelAllow},
		{
			name: "AGENTS.md symlink write blocked", guard: "protect-paths", payload: filePayload("AGENTS.md"), want: LevelBlock,
			setup: func(t *testing.T, root string) {
				writeRepoFile(t, root, "CLAUDE.md", "guide")
				if err := os.Symlink("CLAUDE.md", filepath.Join(root, "AGENTS.md")); err != nil {
					t.Fatalf("symlink: %v", err)
				}
			},
		},
		{
			name: "ask_paths glob asks", guard: "protect-paths", payload: filePayload("wsl-mounts/map_shares.bat"), want: LevelAsk,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"ask_paths":["wsl-mounts/*"]}`) },
		},
		{
			name: "protected_paths outranks ask_paths", guard: "protect-paths", payload: filePayload("secrets/CLAUDE.md"), want: LevelBlock,
			setup: func(t *testing.T, root string) {
				writeSubstrateJSON(t, root, `{"protected_paths":["secrets/*"],"ask_paths":["secrets/*"]}`)
			},
		},
		{
			name: "protected_paths glob hit", guard: "protect-paths", payload: filePayload("secrets/key.pem"),
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"protected_paths":["secrets/*"]}`) },
		},
		{
			name: "contract path hit", guard: "protect-paths", payload: filePayload("docs/generated/x.md"),
			setup: func(t *testing.T, root string) {
				writeSubstrateJSON(t, root, `{"contracts":[{"name":"n","regen":"r","paths":["docs/generated"]}]}`)
			},
		},
		{
			name: "absolute path benign", guard: "protect-paths",
			payload: func(root string) map[string]any {
				return map[string]any{"tool_input": map[string]any{"file_path": filepath.Join(root, "vendor", "thing.go")}}
			},
		},
	}
	runParityVectors(t, vectors)
}

func TestEnginePolicyParityProtectCommand(t *testing.T) {
	vectors := []parityVector{
		{name: "benign command", guard: "protect-command", payload: cmdPayload("ls -la", "")},
		{name: "verify piped blocked", guard: "protect-command", payload: cmdPayload("substrate verify | tee out.txt", "")},
		{name: "verify exact safe", guard: "protect-command", payload: cmdPayload("substrate verify", "")},
		{name: "verify exact safe with dir prefix", guard: "protect-command", payload: cmdPayload("bin/substrate verify", "")},
		{name: "verify with trailing chars blocked", guard: "protect-command", payload: cmdPayload("substrate verify; rm -rf /", "")},
		{name: "jj commit direct blocked", guard: "protect-command", payload: cmdPayload("jj commit -m 'x'", "")},
		{name: "git commit direct blocked", guard: "protect-command", payload: cmdPayload("git commit -am 'x'", "")},
		{name: "direct checkpoint.sh blocked", guard: "protect-command", payload: cmdPayload("bash .substrate/checkpoint.sh", "")},
		{name: "checkpoint session match ok", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session sess-abc.1", "sess-abc.1")},
		{name: "checkpoint session mismatch blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session wrong-id", "sess-abc.1")},
		{name: "checkpoint invalid session blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session x", "")},
		{name: "restructure invalid session blocked", guard: "protect-command", payload: cmdPayload("substrate restructure --session x", "")},
		{name: "restructure session match ok", guard: "protect-command", payload: cmdPayload("substrate restructure --session s1", "s1")},
		{name: "direct restructure.sh blocked", guard: "protect-command", payload: cmdPayload("bash .substrate/restructure.sh", "")},
		{name: "baseline flag asks", guard: "protect-command", payload: cmdPayload("substrate gate --update-baseline", ""), want: LevelAsk},
		{name: "baseline flag with env prefix asks", guard: "protect-command", payload: cmdPayload("SUBSTRATE_ENGINE_BIN=build/substrate-engine ./bin/substrate update --apply --checkpoint --accept-regression=dup_pct --reason 'denominator shrank'", ""), want: LevelAsk},
		{name: "governed mutation outranks baseline flag ask", guard: "protect-command", payload: cmdPayload("substrate gate --update-baseline && rm -rf .substrate", ""), want: LevelBlock},
		{
			name: "corrupt config plus mutator blocked", guard: "protect-command", payload: cmdPayload("rm foo.txt", ""),
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, "{bad") },
		},
		{
			name: "corrupt config blocks substrate config command", guard: "protect-command", payload: cmdPayload("rm substrate.json", ""), want: LevelBlock,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, "{ not json") },
		},
		{name: "mutator basename hit blocked", guard: "protect-command", payload: cmdPayload("rm substrate-baseline.json", "")},
		{name: "substrate config mutation asks", guard: "protect-command", payload: cmdPayload("rm substrate.json", ""), want: LevelAsk},
		{name: "baseline mutation outranks substrate config ask", guard: "protect-command", payload: cmdPayload("rm substrate.json substrate-baseline.json", ""), want: LevelBlock},
		{name: "redirection governed path blocked", guard: "protect-command", payload: cmdPayload("echo x >> .substrate/foo", "")},
		{name: "redirect argval false positive not blocked", guard: "protect-command", payload: cmdPayload(`gh issue comment 16 --body "--reason=<text> mentions substrate-baseline.json in prose"`, "")},
		{name: "indirect write blocked", guard: "protect-command", payload: cmdPayload(`F=".substrate/x"; echo hi >> "$F"`, "")},
		{
			name: "protected_paths literal mutation blocked", guard: "protect-command", payload: cmdPayload("rm secrets/key.pem", ""),
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"protected_paths":["secrets/*"]}`) },
		},
		{
			name: "contract path mutation blocked", guard: "protect-command", payload: cmdPayload("rm docs/generated/x.md", ""),
			setup: func(t *testing.T, root string) {
				writeSubstrateJSON(t, root, `{"contracts":[{"name":"n","regen":"r","paths":["docs/generated"]}]}`)
			},
		},
		{name: "multiline second line trips commit guard", guard: "protect-command", payload: cmdPayload("echo hi\njj commit -m 'x'", "")},
		{name: "multiline false positive no block", guard: "protect-command", payload: cmdPayload("substrate\nverify", "")},
		{name: "embedded quotes and backslashes blocked", guard: "protect-command", payload: cmdPayload(`echo "a\b" && jj commit -m "x"`, "")},
		{name: "perl in-place mutator on CLAUDE.md asks", guard: "protect-command", payload: cmdPayload("perl -pi -e 's/a/b/' CLAUDE.md", ""), want: LevelAsk},
		{name: "redirect into AGENTS.md asks", guard: "protect-command", payload: cmdPayload("echo rule >> sub/AGENTS.md", ""), want: LevelAsk},
		{
			name: "ask_paths literal mutation asks", guard: "protect-command", payload: cmdPayload("rm wsl-mounts/map_shares.bat", ""), want: LevelAsk,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"ask_paths":["wsl-mounts/*"]}`) },
		},
		{
			name: "protected path outranks CLAUDE.md in one command", guard: "protect-command", payload: cmdPayload("rm CLAUDE.md secrets/key.pem", ""), want: LevelBlock,
			setup: func(t *testing.T, root string) { writeSubstrateJSON(t, root, `{"protected_paths":["secrets/*"]}`) },
		},
		{name: "top level command fallback blocked", guard: "protect-command", payload: topLevelCmdPayload("jj commit -m x")},
		{name: "checkpoint accept-regression asks", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=probe:alpha", "s1"), want: LevelAsk},
		{name: "checkpoint accept-regression chained blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a && .substrate/gate.sh --accept-regression=b", "s1"), want: LevelBlock},
		{name: "checkpoint accept-regression process substitution blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a < <(substrate baseline --accept-regression)", "s1"), want: LevelBlock},
		{name: "checkpoint accept-regression command substitution blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a --reason \"$(cat /tmp/r)\"", "s1"), want: LevelBlock},
		{name: "checkpoint accept-regression piped blocked", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a | tail -1", "s1"), want: LevelBlock},
		{name: "unsanctioned program with baseline flag blocked", guard: "protect-command", payload: cmdPayload("echo x --update-baseline", ""), want: LevelBlock},
		{name: "substrate-engine gate accept-regression asks", guard: "protect-command", payload: cmdPayload("substrate-engine gate --accept-regression=dup_pct --reason=denominator", ""), want: LevelAsk},
		{name: "checkpoint tighten flag asks", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --tighten", "s1"), want: LevelAsk},
		{name: "checkpoint accept-regression trailing newline asks", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a\n", "s1"), want: LevelAsk},
		{name: "checkpoint accept-regression u3000 locale split asks", guard: "protect-command", payload: cmdPayload("substrate checkpoint --session s1 --accept-regression=a\u3000--tighten", "s1"), want: LevelAsk},
	}
	runParityVectors(t, vectors)
}

func TestEnginePolicyParityEnforceJJ(t *testing.T) {
	vectors := []parityVector{
		{name: "no jj dir is no-op", guard: "enforce-jj", payload: cmdPayload("git commit -m x", "")},
		{name: "jj repo benign git status", guard: "enforce-jj", payload: cmdPayload("git status", ""), setup: makeJJRepo},
		{name: "jj repo git commit blocked", guard: "enforce-jj", payload: cmdPayload("git commit -m x", ""), setup: makeJJRepo},
		{name: "jj repo git add blocked", guard: "enforce-jj", payload: cmdPayload("git add .", ""), setup: makeJJRepo},
		{name: "jj git push not blocked by mutate pattern", guard: "enforce-jj", payload: cmdPayload("jj git push", ""), setup: makeJJRepo},
		{name: "plain git push blocked", guard: "enforce-jj", payload: cmdPayload("git push origin main", ""), setup: makeJJRepo},
		{name: "git push --tags exempt", guard: "enforce-jj", payload: cmdPayload("git push --tags", ""), setup: makeJJRepo},
		{name: "git push version tag exempt", guard: "enforce-jj", payload: cmdPayload("git push origin v1.2.3", ""), setup: makeJJRepo},
		{name: "multiline second line trips mutate guard", guard: "enforce-jj", payload: cmdPayload("echo hi\ngit commit -m x", ""), setup: makeJJRepo},
		{name: "multiline false positive no block", guard: "enforce-jj", payload: cmdPayload("git\ncommit -m x", ""), setup: makeJJRepo},
	}
	runParityVectors(t, vectors)
}

func TestEnginePolicyParityEnforceConventionalCommits(t *testing.T) {
	vectors := []parityVector{
		{name: "no jj dir is no-op", guard: "enforce-conventional-commits", payload: cmdPayload("jj commit -m 'bad'", "")},
		{name: "jj repo non-trigger command", guard: "enforce-conventional-commits", payload: cmdPayload("jj status", ""), setup: makeJJRepo},
		{name: "jj repo bad message blocked", guard: "enforce-conventional-commits", payload: cmdPayload("jj commit -m 'bad message'", ""), setup: makeJJRepo},
		{name: "jj repo good message ok", guard: "enforce-conventional-commits", payload: cmdPayload("jj commit -m 'feat(auth): add login'", ""), setup: makeJJRepo},
		{name: "jj describe good message ok", guard: "enforce-conventional-commits", payload: cmdPayload("jj describe -m 'fix: bug'", ""), setup: makeJJRepo},
		{name: "jj commit without message flag no-op", guard: "enforce-conventional-commits", payload: cmdPayload("jj commit", ""), setup: makeJJRepo},
		{name: "multiline second line trips message guard", guard: "enforce-conventional-commits", payload: cmdPayload("echo hi\njj commit -m 'bad message'", ""), setup: makeJJRepo},
		{name: "double quoted conventional message ok", guard: "enforce-conventional-commits", payload: cmdPayload(`jj commit -m "feat(x): add"`, ""), setup: makeJJRepo},
	}
	runParityVectors(t, vectors)
}
