package main

import (
	"sync"
	"testing"
)

// The hazard parallelism introduces: two workers claiming the same filename
// means Proton turns the second upload into a new revision of the first,
// hiding one photo behind another. No two callers may ever hold the same
// name.
func TestNameReserverGivesEachNameOnce(t *testing.T) {
	r := newNameReserver()

	if !r.claimForTest("IMG_1234.HEIC") {
		t.Fatal("first claim should succeed")
	}
	if r.claimForTest("IMG_1234.HEIC") {
		t.Error("the same name was handed out twice")
	}
	// Proton filenames are case-insensitive for collision purposes.
	if r.claimForTest("img_1234.heic") {
		t.Error("a case variant was treated as a different name")
	}
}

func TestNameReserverReleaseAllowsReuse(t *testing.T) {
	r := newNameReserver()

	r.claimForTest("IMG_1.HEIC")
	r.release("IMG_1.HEIC")

	if !r.claimForTest("IMG_1.HEIC") {
		t.Error("a released name should be claimable again -- otherwise a failed upload burns the name for the rest of the run")
	}
}

// Run with -race: concurrent claims of the same name must yield exactly one
// winner.
func TestNameReserverIsRaceFree(t *testing.T) {
	r := newNameReserver()

	const workers = 50
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins := 0

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if r.claimForTest("image000000.jpg") {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if wins != 1 {
		t.Errorf("%d workers claimed the same name, want exactly 1", wins)
	}
}
