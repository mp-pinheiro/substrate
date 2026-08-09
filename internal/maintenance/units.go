package maintenance

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func UnitsJSON(unitsFilePath string, candidateDir string) ([]Unit, error) {
	f, err := os.Open(unitsFilePath)
	if err != nil {
		return nil, fmt.Errorf("units json: open %s: %w", unitsFilePath, err)
	}
	defer func() { _ = f.Close() }()

	var units []Unit
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		path := scanner.Text()
		if path == "" {
			continue
		}

		preimage, err := PathState(path)
		if err != nil {
			return nil, fmt.Errorf("units json: pathstate preimage %s: %w", path, err)
		}

		candidatePath := filepath.Join(candidateDir, path)
		desired, err := PathState(candidatePath)
		if err != nil {
			return nil, fmt.Errorf("units json: pathstate desired %s: %w", candidatePath, err)
		}

		units = append(units, Unit{
			Path:     path,
			Preimage: preimage,
			Desired:  desired,
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("units json: read %s: %w", unitsFilePath, err)
	}

	sort.Slice(units, func(i, j int) bool { return units[i].Path < units[j].Path })
	return units, nil
}

func UnitsMatchPreimage(receiptPath string) error {
	data, err := os.ReadFile(receiptPath)
	if err != nil {
		return fmt.Errorf("units match preimage: read %s: %w", receiptPath, err)
	}

	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return fmt.Errorf("units match preimage: parse %s: %w", receiptPath, err)
	}

	for _, unit := range receipt.Repository.Units {
		state, err := PathState(unit.Path)
		if err != nil {
			return fmt.Errorf("units match preimage: pathstate %s: %w", unit.Path, err)
		}
		if state != unit.Preimage {
			return fmt.Errorf("units match preimage: %s: preimage mismatch (expected %s, got %s)", unit.Path, unit.Preimage, state)
		}
	}

	return nil
}
