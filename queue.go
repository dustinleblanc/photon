package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"photon/internal/store"
	"photon/proton"
)

// uploadWorkers is how many assets are processed at once. Each one costs
// roughly six seconds spread evenly across export, two thumbnail renders,
// encryption and upload, so the only real lever on total runtime is doing
// several at a time. The bridge's block-upload and crypto semaphores are
// shared and already sized well above this, so they keep the actual load on
// Proton bounded regardless.
var uploadWorkers = intFromEnv("PHOTON_UPLOAD_WORKERS", 3)

func intFromEnv(name string, fallback int) int {
	if raw := os.Getenv(name); raw != "" {
		var n int
		if _, err := fmt.Sscanf(raw, "%d", &n); err == nil && n > 0 {
			return n
		}
		fmt.Fprintf(os.Stderr, "warning: ignoring unusable %s=%q\n", name, raw)
	}
	return fallback
}

// nameReserver stops two workers claiming the same filename.
//
// This is the hazard that makes naive parallelism unsafe here: filename
// collisions are common (thousands of assets share names like
// image000000.jpg), and if two workers both find "icon (98).png" free
// before either creates it, Proton treats the second upload as a *new
// revision of the first file* -- burying one photo behind another rather
// than reporting a conflict. Reserving names in-process closes that window;
// the cross-process case is already covered by the upload lock.
type nameReserver struct {
	mu    sync.Mutex
	taken map[string]bool
}

func newNameReserver() *nameReserver {
	return &nameReserver{taken: make(map[string]bool)}
}

// reserve claims preferred if it is free, otherwise finds and claims the
// next available variant. Held under one lock so that choosing and claiming
// cannot interleave between workers.
func (r *nameReserver) reserve(ctx context.Context, drive *proton.Drive, preferred string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if !r.taken[strings.ToLower(preferred)] {
		r.taken[strings.ToLower(preferred)] = true
		return preferred, nil
	}

	alternative, err := proton.FindAvailableName(ctx, drive, preferred, func(candidate string) bool {
		return r.taken[strings.ToLower(candidate)]
	})
	if err != nil {
		return "", err
	}
	r.taken[strings.ToLower(alternative)] = true
	return alternative, nil
}

// claimForTest claims a name without consulting the server. reserve() is
// the real entry point; this exposes just the reservation half so the
// concurrency guarantee can be tested without a live connection.
func (r *nameReserver) claimForTest(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := strings.ToLower(name)
	if r.taken[key] {
		return false
	}
	r.taken[key] = true
	return true
}

// release frees a name whose upload did not complete, so a later asset (or
// a re-run) can use it.
func (r *nameReserver) release(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.taken, strings.ToLower(name))
}

// queueOutcome is how a processed asset should be recorded.
type queueOutcome int

const (
	outcomeUploaded queueOutcome = iota
	outcomeSkipped
	outcomeFailed
	outcomeInterrupted
)

// queueConfig is the difference between the two upload passes: the normal
// batch (which skips anything already on Proton) and the thumbnail backfill
// (which deliberately re-uploads to attach previews to a new revision).
type queueConfig struct {
	items        []store.PendingItem
	helperPath   string
	checkDupes   bool
	requireThumb bool
	verb         string // "uploaded" / "backfilled", for output
	record       func(item store.PendingItem, linkID string, thumbCount int) error
}

type queueTally struct {
	uploaded, skipped, failed atomic.Int64
}

// runUploadQueue processes items concurrently, recording each result as it
// completes. Shared by the batch and backfill passes, which previously were
// two near-identical loops.
func runUploadQueue(ctx context.Context, drive *proton.Drive, s *store.Store, cfg queueConfig) *queueTally {
	var (
		tally     = &queueTally{}
		completed atomic.Int64
		outputMu  sync.Mutex
		reserver  = newNameReserver()
		total     = len(cfg.items)
	)

	// Serialised so concurrent workers don't interleave half-lines, and so
	// the "[k/n]" counter the GUI parses stays monotonic (k counts
	// completions, not queue position).
	report := func(format string, args ...any) {
		outputMu.Lock()
		defer outputMu.Unlock()
		fmt.Printf(format, args...)
	}
	reportErr := func(format string, args ...any) {
		outputMu.Lock()
		defer outputMu.Unlock()
		fmt.Fprintf(os.Stderr, format, args...)
	}

	jobs := make(chan store.PendingItem)
	var wg sync.WaitGroup

	for w := 0; w < uploadWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for item := range jobs {
				if ctx.Err() != nil {
					return
				}
				outcome := processQueueItem(ctx, drive, s, cfg, reserver, item, report, reportErr, &completed, total)
				switch outcome {
				case outcomeUploaded:
					tally.uploaded.Add(1)
				case outcomeSkipped:
					tally.skipped.Add(1)
				case outcomeFailed:
					tally.failed.Add(1)
				case outcomeInterrupted:
					return
				}
			}
		}()
	}

	for _, item := range cfg.items {
		if ctx.Err() != nil {
			break
		}
		select {
		case jobs <- item:
		case <-ctx.Done():
		}
	}
	close(jobs)
	wg.Wait()

	return tally
}

func processQueueItem(
	ctx context.Context,
	drive *proton.Drive,
	s *store.Store,
	cfg queueConfig,
	reserver *nameReserver,
	item store.PendingItem,
	report func(string, ...any),
	reportErr func(string, ...any),
	completed *atomic.Int64,
	total int,
) queueOutcome {
	filename := filenameForVersion(item.OriginalFilename, item.Version)
	modTime := time.Unix(int64(item.CreationDate), 0)

	if cfg.checkDupes {
		resolved, dupLinkID, err := resolveNameCollision(ctx, drive, cfg.helperPath, item, filename)
		if err != nil {
			reportErr("  warning: duplicate check failed for %s, uploading anyway: %v\n", filename, err)
		} else if dupLinkID != "" {
			n := completed.Add(1)
			if markErr := s.MarkSkippedDuplicate(item.LocalIdentifier, item.Version, ""); markErr != nil {
				reportErr("warning: failed to record skip: %v\n", markErr)
			}
			report("[%d/%d] already on Proton, skipping %s (%s) -> %s\n", n, total, filename, item.Version, dupLinkID)
			return outcomeSkipped
		} else {
			filename = resolved
		}
	}

	// Claim the name before uploading so no other worker can pick it.
	claimed, err := reserver.reserve(ctx, drive, filename)
	if err != nil {
		n := completed.Add(1)
		reportErr("[%d/%d] FAILED %s: could not find a free name: %v\n", n, total, filename, err)
		return outcomeFailed
	}
	if claimed != filename {
		report("  %s is taken, uploading as %s\n", filename, claimed)
	}
	filename = claimed

	var linkID string
	var thumbCount int
	err = withRetry(ctx, filename, func() error {
		var attemptErr error
		linkID, thumbCount, attemptErr = uploadOneFromHelper(ctx, drive, cfg.helperPath, item.LocalIdentifier, item.Version, filename, modTime)
		return attemptErr
	})

	if err != nil {
		reserver.release(filename)

		// Stop/quit cancels the in-flight asset. That is not a failure:
		// recording it as one would silently drop the photo, since failed
		// rows are never retried.
		if ctx.Err() != nil {
			report("stopping: interrupted (%s left pending)\n", filename)
			return outcomeInterrupted
		}

		n := completed.Add(1)
		if markErr := s.MarkFailed(item.LocalIdentifier, item.Version, err.Error()); markErr != nil {
			reportErr("warning: failed to record failure: %v\n", markErr)
		}
		reportErr("[%d/%d] FAILED %s (%s): %v\n", n, total, filename, item.Version, err)
		return outcomeFailed
	}

	if cfg.requireThumb && thumbCount == 0 {
		reserver.release(filename)
		n := completed.Add(1)
		reportErr("[%d/%d] no thumbnail could be rendered for %s, leaving queued\n", n, total, filename)
		return outcomeFailed
	}

	n := completed.Add(1)
	if markErr := cfg.record(item, linkID, thumbCount); markErr != nil {
		reportErr("warning: failed to record success: %v\n", markErr)
	}

	note := ""
	if thumbCount == 0 {
		note = " (no thumbnail)"
	}
	report("[%d/%d] %s %s (%s)%s -> %s\n", n, total, cfg.verb, filename, item.Version, note, linkID)
	return outcomeUploaded
}
