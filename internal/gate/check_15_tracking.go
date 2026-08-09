package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func check15Tracking(ctx context.Context, inv []string, claims []byte, env map[string]string) (int, []MetricRecord, string, error) {
	repoRoot := env["REPO_ROOT"]
	plansDir := filepath.Join(repoRoot, ".pi", "plans")

	if _, err := os.Stat(plansDir); os.IsNotExist(err) {
		return 0, nil, "", nil
	}

	entries, err := os.ReadDir(plansDir)
	if err != nil {
		return 0, nil, "", nil
	}

	validStates := map[string]bool{
		"draft": true, "active": true, "committed": true, "superseded": true, "abandoned": true,
	}

	var findings []string
	rc := 0
	found := 0

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		found = 1
		planPath := filepath.Join(plansDir, e.Name())
		rel := ".pi/plans/" + e.Name()

		data, err := os.ReadFile(planPath)
		if err != nil {
			continue
		}
		lines := strings.Split(string(data), "\n")

		var stateLines []string
		for _, line := range lines {
			if strings.HasPrefix(line, "state: ") {
				stateLines = append(stateLines, line)
			}
		}
		if len(stateLines) != 1 {
			findings = append(findings, fmt.Sprintf("%s — needs exactly one \"state: draft|active|committed|superseded|abandoned\" line", rel))
			rc = 1
			continue
		}

		state := strings.TrimPrefix(stateLines[0], "state: ")
		state = strings.Fields(state)[0]
		if !validStates[state] {
			findings = append(findings, fmt.Sprintf("%s — needs exactly one \"state: draft|active|committed|superseded|abandoned\" line", rel))
			rc = 1
			continue
		}

		items := 0
		unchecked := 0
		malformed := 0
		inAcceptance := false
		for _, line := range lines {
			if strings.HasPrefix(line, "## Acceptance") {
				inAcceptance = true
				continue
			}
			if strings.HasPrefix(line, "## ") {
				inAcceptance = false
				continue
			}
			if !inAcceptance {
				continue
			}
			if strings.HasPrefix(line, "- [") {
				if strings.Contains(line, " :: ") {
					items++
					if strings.HasPrefix(line, "- [ ]") {
						unchecked++
					}
				} else {
					findings = append(findings, fmt.Sprintf("%s — malformed acceptance item (want \"- [ ] claim :: verify-cmd\"): %s", rel, line))
					malformed++
				}
			}
		}

		if malformed > 0 {
			rc = 1
		}
		if state == "active" && items == 0 {
			findings = append(findings, fmt.Sprintf("%s — active plan with no acceptance oracles (add \"## Acceptance\" items or change state)", rel))
			rc = 1
		}
		if state == "committed" && unchecked > 0 {
			findings = append(findings, fmt.Sprintf("%s — committed plan with %d unchecked item(s): a committed plan claims done", rel, unchecked))
			rc = 1
		}
		if state == "committed" && items == 0 {
			hasAcceptanceNone := false
			for _, line := range lines {
				if strings.HasPrefix(line, "acceptance: none — ") {
					hasAcceptanceNone = true
					break
				}
			}
			if !hasAcceptanceNone {
				findings = append(findings, fmt.Sprintf("%s — committed plan with no oracles needs \"acceptance: none — <reason>\" (done-claims are verifiable or explicitly waived)", rel))
				rc = 1
			}
		}
		if state == "superseded" {
			has := false
			for _, line := range lines {
				if strings.HasPrefix(line, "superseded-by: ") {
					has = true
					break
				}
			}
			if !has {
				findings = append(findings, fmt.Sprintf("%s — superseded plan needs a \"superseded-by: <where>\" pointer (a state without a link is silence)", rel))
				rc = 1
			}
		}
		if state == "abandoned" {
			has := false
			for _, line := range lines {
				if strings.HasPrefix(line, "reason: ") {
					has = true
					break
				}
			}
			if !has {
				findings = append(findings, fmt.Sprintf("%s — abandoned plan needs a \"reason:\" line", rel))
				rc = 1
			}
		}
	}

	if found == 0 {
		return 0, nil, "", nil
	}
	return rc, nil, strings.Join(findings, "\n"), nil
}
