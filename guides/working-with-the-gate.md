# Working with the Gate

Task guide for reading `substrate gate` failures and acting on them. The canonical contracts (exit codes, ratchet semantics, hatches) are in [`docs/contracts.md`](../docs/contracts.md) — this page maps failure output to the fix.

## Failure → action

```
src/foo.xyz: claimed by no profile — add a profile claim or list it in substrate.json unscanned
[!] FAIL 05-unclaimed-source
```
Every tracked source file must be claimed by an active profile or listed in the `unscanned` ledger. Add the profile (`substrate.json` profiles + `substrate update --apply`), add a claim to a repo-local profile, or — for genuinely unscannable files — add a reviewed glob to `unscanned`.

```
src/foo.sh:12: narration: # now we check the thing
comment gate: remove the flagged comments or encode the fact in names/structure.
[!] FAIL 10-comments
```
Delete the flagged comment or move the fact into a name. Each file has its own grandfathered allowance in `substrate-baseline.json`; new files have zero. A rare keeper stays with `gate:allow-comment` appended to the line.

```
.pi/plans/foo.md — malformed acceptance item (want "- [ ] claim :: verify-cmd"): ...
.pi/plans/foo.md — committed plan with 2 unchecked item(s): a committed plan claims done
[!] FAIL 15-tracking
```
Plans are gated artifacts: exactly one `state:` line, acceptance items in executable form, committed state requires all boxes checked. Fix the plan file, or change its state honestly (supersede/abandon — a state, not silence).

```
[!] FAIL 20-duplication: 0.41% exceeds baseline 0.28%
```
You copy-pasted something jscpd can see. Extract the shared shape into a helper and call it from both sites. `substrate report` lists the worst clusters with file:line spans.

```
src/big.py: 612 lines exceeds the hard cap 500 — split it (budgets.max_file_lines in substrate.json)
[!] FAIL 30-budgets
```
Split the file. Raising the cap is a config diff everyone sees.

```
invalid JSON: config/foo.json
[!] FAIL 40-data-validity
```
Fix the file; jq/yq must parse every tracked data file.

```
potential secrets in git history — run: gitleaks detect --no-banner
[!] FAIL 50-gitleaks
```
Rotate the secret first, then scrub history. Never just delete the file — the leak is in history.

```
fixtures/bad-vet.go:9: ... (profile check output)
[!] FAIL 61-go-vet
```
Profile checks (60–79) print tool-native findings, each line `file:line — problem — fix`. Fix the finding; intentional exceptions use the tool's own line-scoped directive with a reason.

## Ratchets: improving and locking in

Improvements print a hint instead of auto-tightening:

```
[+] dup_pct: 0.26 improved on baseline 0.28 — run --update-baseline to lock it in
```

```sh
substrate baseline --update              # refuses while any check fails
substrate baseline --accept-regression   # deliberate loosening; prints the exact diff
```

When `substrate-baseline.json` exists, an absent metric key means zero tolerance — new debt categories start at zero.

## When the gate itself breaks

The gate fails closed. Infrastructure failures (check exit >= 2) are their own loud category and never read as "no findings":

```
[!] FAIL 20-duplication: jscpd failed (rc=7) — the gate cannot pass blind
[!] substrate-baseline.json is corrupt — restore it from VCS or rerun --update-baseline
```

Fix the tool (`substrate doctor` names what's missing and where to get it), not the check. If you ever see a green gate you don't trust, break something on purpose — `substrate selftest` does exactly that, systematically: slop injection must go red, a shimmed-broken tool must go red, a corrupt baseline must hard-exit.

## Harness hook timing

Write-time hooks arm when a session starts: installing or updating the kit mid-session leaves the running harness on the old hooks until restart. The deterministic backstops are `just gate` before push and CI — treat in-session hooks as fast feedback, not the only net.
