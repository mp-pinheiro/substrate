package receipt

import (
	"context"
	"fmt"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// The human renderer leaks subjects, abbreviated ids and "(behind by N commits)" into the digest.
const jjBookmarkTemplate = `name ++ "\x1f" ++ if(remote, remote, "") ++ "\x1f" ++ ` +
	`if(normal_target, normal_target.commit_id(), "") ++ "\n"`

// One merged byte-sort over git and jj records (H9); bash sorted git, then appended jj unsorted.
func computeRefsHash(ctx context.Context, repo *vcs.Repo) (string, error) {
	var records [][]byte

	gitDirRes, err := xshell.RunInC(ctx, repo.Root, "git", "rev-parse", "--git-dir")
	if err != nil {
		return "", fmt.Errorf("receipt: run git rev-parse --git-dir: %w", err)
	}
	if gitDirRes.Code == 0 {
		refRecords, err := gitRefRecords(ctx, repo.Root)
		if err != nil {
			return "", err
		}
		records = append(records, refRecords...)

		headRecord, err := gitHeadRecord(ctx, repo.Root)
		if err != nil {
			return "", err
		}
		records = append(records, headRecord)
	}

	if repo.Kind == vcs.KindJJ {
		bookmarkRecords, err := jjBookmarkRecords(ctx, repo.Root)
		if err != nil {
			return "", err
		}
		records = append(records, bookmarkRecords...)
	}

	return hashRecords(records)
}

func gitRefRecords(ctx context.Context, root string) ([][]byte, error) {
	res, err := xshell.RunInC(ctx, root, "git", "for-each-ref",
		"--format=%(refname) %(objectname)", "refs/heads", "refs/tags", "refs/remotes")
	if err != nil {
		return nil, fmt.Errorf("receipt: run git for-each-ref: %w", err)
	}
	if res.Code != 0 {
		return nil, fmt.Errorf("receipt: git for-each-ref exited %d", res.Code)
	}
	var records [][]byte
	for _, line := range linesOf(res.Stdout) {
		fields := strings.SplitN(line, " ", 2)
		if len(fields) != 2 {
			return nil, fmt.Errorf("receipt: malformed for-each-ref line %q", line)
		}
		records = append(records, joinFields("git-ref", fields[0], fields[1]))
	}
	return records, nil
}

// gitHeadRecord makes "HEAD is detached" an explicit record (H9) rather
// than the absent line bash's `|| true` produces.
func gitHeadRecord(ctx context.Context, root string) ([]byte, error) {
	res, err := xshell.RunInC(ctx, root, "git", "symbolic-ref", "-q", "HEAD")
	if err != nil {
		return nil, fmt.Errorf("receipt: run git symbolic-ref: %w", err)
	}
	if res.Code == 0 {
		target := strings.TrimRight(string(res.Stdout), "\n")
		return joinFields("head", "symbolic", target), nil
	}
	return joinFields("head", "detached"), nil
}

func jjBookmarkRecords(ctx context.Context, root string) ([][]byte, error) {
	res, err := xshell.RunInC(ctx, root, "jj", "bookmark", "list", "--all-remotes", "-T", jjBookmarkTemplate)
	if err != nil {
		return nil, fmt.Errorf("receipt: run jj bookmark list: %w", err)
	}
	if res.Code != 0 {
		return nil, fmt.Errorf("receipt: jj bookmark list exited %d", res.Code)
	}
	var records [][]byte
	for _, line := range linesOf(res.Stdout) {
		fields := strings.Split(line, "\x1f")
		if len(fields) != 3 {
			return nil, fmt.Errorf("receipt: malformed jj bookmark line %q", line)
		}
		records = append(records, joinFields("jj-bookmark", fields[0], fields[1], fields[2]))
	}
	return records, nil
}

// linesOf splits LF-terminated command output into non-blank lines.
func linesOf(stdout []byte) []string {
	var lines []string
	for _, line := range strings.Split(strings.TrimRight(string(stdout), "\n"), "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}
