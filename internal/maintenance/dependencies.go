package maintenance

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

func provisionCandidateDependencies(sourceRoot, candidateDir string) ([]string, error) {
	links := make([]string, 0)
	err := filepath.WalkDir(candidateDir, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fmt.Errorf("walk %s: %w", path, walkErr)
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".substrate", "node_modules":
				return filepath.SkipDir
			default:
				return nil
			}
		}
		if entry.Name() != "bun.lock" {
			return nil
		}
		relDir, err := filepath.Rel(candidateDir, filepath.Dir(path))
		if err != nil {
			return fmt.Errorf("resolve candidate dependency path: %w", err)
		}
		source := filepath.Join(sourceRoot, relDir, "node_modules")
		info, err := os.Stat(source)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("stat dependency %s: %w", source, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("dependency path is not a directory: %s", source)
		}
		source, err = filepath.EvalSymlinks(source)
		if err != nil {
			return fmt.Errorf("resolve dependency %s: %w", source, err)
		}
		target := filepath.Join(candidateDir, relDir, "node_modules")
		if _, err := os.Lstat(target); err == nil {
			return nil
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("stat candidate dependency %s: %w", target, err)
		}
		if err := os.Symlink(source, target); err != nil {
			return fmt.Errorf("link candidate dependency %s: %w", target, err)
		}
		links = append(links, target)
		return nil
	})
	if err != nil {
		_ = cleanupCandidateDependencies(links)
		return nil, fmt.Errorf("walk candidate dependencies: %w", err)
	}
	return links, nil
}

func cleanupCandidateDependencies(links []string) error {
	for index := len(links) - 1; index >= 0; index-- {
		if err := os.Remove(links[index]); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove candidate dependency %s: %w", links[index], err)
		}
	}
	return nil
}
