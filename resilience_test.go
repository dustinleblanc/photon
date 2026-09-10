package main

import (
	"context"
	"errors"
	"io"
	"testing"
	"time"

	papi "github.com/ProtonMail/go-proton-api"
)

func TestIsTransient(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		// The exact failure that silently dropped five photos.
		{"proton 502 as text", errors.New("502 POST https://zrh-storage.proton.me/storage/blocks: 502 Bad Gateway (Code=0, Status=502)"), true},
		{"api error 503", &papi.APIError{Status: 503}, true},
		{"api error 500", &papi.APIError{Status: 500}, true},
		{"deadline exceeded", context.DeadlineExceeded, true},
		{"unexpected eof", io.ErrUnexpectedEOF, true},
		{"connection reset", errors.New("read tcp: connection reset by peer"), true},

		// Must NOT retry: these are permanent, and retrying wastes a minute
		// per photo across thousands of them.
		{"missing resource", errors.New("export failed: exit status 1: no original resource available for X/L0/001"), false},
		{"api error 422", &papi.APIError{Status: 422}, false},
		{"api error 401", &papi.APIError{Status: 401}, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := isTransient(tc.err); got != tc.want {
				t.Errorf("isTransient(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

func TestWithRetryStopsOnPermanentError(t *testing.T) {
	calls := 0
	err := withRetry(context.Background(), "test", func() error {
		calls++
		return errors.New("no original resource available")
	})

	if err == nil {
		t.Fatal("expected the error to be returned")
	}
	if calls != 1 {
		t.Errorf("permanent error retried %d times, want 1 attempt only", calls)
	}
}

func TestWithRetrySucceedsAfterTransientFailure(t *testing.T) {
	// Keep the test fast: one short backoff step.
	original := retryBackoff
	retryBackoff = []time.Duration{time.Millisecond}
	defer func() { retryBackoff = original }()

	calls := 0
	err := withRetry(context.Background(), "test", func() error {
		calls++
		if calls == 1 {
			return errors.New("502 Bad Gateway")
		}
		return nil
	})

	if err != nil {
		t.Fatalf("expected success on retry, got %v", err)
	}
	if calls != 2 {
		t.Errorf("got %d attempts, want 2", calls)
	}
}

func TestWithRetryHonoursCancellation(t *testing.T) {
	original := retryBackoff
	retryBackoff = []time.Duration{time.Hour} // would hang if cancellation were ignored
	defer func() { retryBackoff = original }()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan error, 1)
	go func() {
		done <- withRetry(ctx, "test", func() error { return errors.New("503 Service Unavailable") })
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("withRetry ignored a cancelled context")
	}
}

func TestStallReaderTracksProgress(t *testing.T) {
	pr, pw := io.Pipe()
	reader := newStallReader(pr)

	go func() {
		_, _ = pw.Write([]byte("hello"))
		_ = pw.Close()
	}()

	buf := make([]byte, 5)
	if _, err := reader.Read(buf); err != nil {
		t.Fatalf("read: %v", err)
	}

	if idle := reader.idleFor(); idle > time.Second {
		t.Errorf("idleFor = %v right after a read, want ~0", idle)
	}
}
