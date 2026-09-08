package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"time"

	papi "github.com/ProtonMail/go-proton-api"
)

// Timeouts for the PhotoKit helper. An asset that lives only in iCloud has
// to be downloaded before it can be exported, and that request can wedge
// indefinitely: PHAssetResourceManager takes no timeout, so a stalled
// download blocks the helper forever and, with it, the whole batch. (Seen
// in practice: a 2019 video held the queue for 30 minutes at 0% CPU.)
//
// The export uses a *stall* timeout rather than a total deadline, because a
// large video legitimately takes a long time -- what marks it as wedged is
// receiving no bytes at all for this long.
var (
	exportStallTimeout = durationFromEnv("PHOTON_EXPORT_STALL_TIMEOUT", 5*time.Minute)
	thumbnailTimeout   = durationFromEnv("PHOTON_THUMBNAIL_TIMEOUT", 2*time.Minute)
)

func durationFromEnv(name string, fallback time.Duration) time.Duration {
	if raw := os.Getenv(name); raw != "" {
		if d, err := time.ParseDuration(raw); err == nil {
			return d
		}
		fmt.Fprintf(os.Stderr, "warning: ignoring unparseable %s=%q\n", name, raw)
	}
	return fallback
}

// stallReader notes when bytes last arrived so a watchdog can tell a slow
// transfer apart from a dead one.
type stallReader struct {
	inner    io.Reader
	lastRead atomic.Int64 // unix nanos
	total    atomic.Int64
}

func newStallReader(r io.Reader) *stallReader {
	sr := &stallReader{inner: r}
	sr.lastRead.Store(time.Now().UnixNano())
	return sr
}

func (s *stallReader) Read(p []byte) (int, error) {
	n, err := s.inner.Read(p)
	if n > 0 {
		s.lastRead.Store(time.Now().UnixNano())
		s.total.Add(int64(n))
	}
	return n, err
}

// bytesRead reports the total seen so far. An export yielding zero bytes
// means the asset could not be materialised, which Proton otherwise
// reports only as an opaque "Upload file empty".
func (s *stallReader) bytesRead() int64 { return s.total.Load() }

func (s *stallReader) idleFor() time.Duration {
	return time.Since(time.Unix(0, s.lastRead.Load()))
}

// watchForStall kills onStall's target once no bytes have arrived for
// timeout. Returns a stop function to call when the transfer finishes.
func watchForStall(reader *stallReader, timeout time.Duration, kill func(), describe string) func() {
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if reader.idleFor() > timeout {
					fmt.Fprintf(os.Stderr, "  no data for %s on %s, abandoning it\n",
						reader.idleFor().Round(time.Second), describe)
					kill()
					return
				}
			}
		}
	}()
	return func() { close(done) }
}

// isTransient reports whether an upload failure is worth retrying rather
// than recording as a permanent failure. Proton's storage backend returns
// occasional 502s, and marking those failed silently drops photos from the
// migration -- which is exactly what happened to five of them before this
// existed.
func isTransient(err error) bool {
	if err == nil {
		return false
	}

	var apiErr *papi.APIError
	if errors.As(err, &apiErr) && apiErr.Status >= 500 {
		return true
	}

	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}

	// The bridge wraps some failures as plain errors, so fall back to the
	// status text rather than letting a retryable one through as fatal.
	text := err.Error()
	for _, marker := range []string{
		"Status=500", "Status=502", "Status=503", "Status=504",
		"Bad Gateway", "Service Unavailable", "Gateway Timeout",
		"connection reset", "EOF", "timeout",
	} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

// retryBackoff is deliberately short and few: a batch of thousands should
// keep moving, and anything still failing after a minute of retries is
// better recorded as failed and revisited later.
var retryBackoff = []time.Duration{5 * time.Second, 15 * time.Second, 45 * time.Second}

// withRetry runs attempt until it succeeds, hits a non-transient error, or
// runs out of backoff.
func withRetry(ctx context.Context, describe string, attempt func() error) error {
	var err error
	for i := 0; ; i++ {
		err = attempt()
		if err == nil || !isTransient(err) || i >= len(retryBackoff) {
			return err
		}

		wait := retryBackoff[i]
		fmt.Fprintf(os.Stderr, "  %s: %v -- retrying in %s (attempt %d of %d)\n",
			describe, err, wait, i+2, len(retryBackoff)+1)

		select {
		case <-ctx.Done():
			return err
		case <-time.After(wait):
		}
	}
}
