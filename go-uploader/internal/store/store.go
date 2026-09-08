package store

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"

	_ "modernc.org/sqlite"

	"photon-migrate/internal/asset"
)

type Status string

const (
	StatusPending          Status = "pending"
	StatusUploaded         Status = "uploaded"
	StatusSkippedDuplicate Status = "skipped_duplicate"
	StatusFailed           Status = "failed"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	// Owner-only regardless: this records the whole contents of a photo
	// library, even though credentials live in the Keychain rather than here.
	if err := os.Chmod(path, 0o600); err != nil && !os.IsNotExist(err) {
		db.Close()
		return nil, fmt.Errorf("restrict db permissions: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	// WAL lets the GUI read status while a batch upload is writing to the
	// same database; busy_timeout covers the brief exclusive moments WAL
	// still has (checkpoints), so a concurrent reader waits instead of
	// failing outright with "database is locked".
	if _, err := s.db.Exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;`); err != nil {
		return fmt.Errorf("configure db concurrency: %w", err)
	}

	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS assets (
	local_identifier   TEXT NOT NULL,
	version            TEXT NOT NULL,
	original_filename  TEXT,
	creation_date      REAL,
	content_hash       TEXT,
	proton_link_id     TEXT,
	status             TEXT NOT NULL DEFAULT 'pending',
	last_attempt_at    REAL,
	error              TEXT,
	PRIMARY KEY (local_identifier, version)
);
CREATE INDEX IF NOT EXISTS idx_assets_status ON assets(status);

CREATE TABLE IF NOT EXISTS locks (
	name        TEXT PRIMARY KEY,
	pid         INTEGER NOT NULL,
	acquired_at REAL
);
`)
	if err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	// has_thumbnails distinguishes uploads that included previews from ones
	// that didn't. Thumbnails can only be attached while a revision is
	// uploading -- there's no API to add them afterwards -- so rows without
	// them need a fresh revision, which is what backfill-thumbnails does.
	// ALTER TABLE ADD COLUMN has no IF NOT EXISTS in SQLite, so a duplicate
	// column error here just means the migration already ran.
	if _, err := s.db.Exec(`ALTER TABLE assets ADD COLUMN has_thumbnails INTEGER NOT NULL DEFAULT 0`); err != nil &&
		!strings.Contains(err.Error(), "duplicate column name") {
		return fmt.Errorf("migrate has_thumbnails: %w", err)
	}

	return nil
}

// Advisory locking. Two concurrent batches would each take their own slice
// of the pending list, overlap, and upload the same photos twice (the
// server-side dedup check only catches what is already committed), so a
// second batch refuses to start while one is live.

var ErrLockHeld = errors.New("another upload batch is already running")

// AcquireLock takes the named lock for this process. A lock left behind by
// a crashed run is taken over once its PID is gone -- otherwise a hard kill
// would wedge the tool until someone cleared the row by hand.
func (s *Store) AcquireLock(name string) error {
	pid := os.Getpid()

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var holderPID int
	err = tx.QueryRow(`SELECT pid FROM locks WHERE name = ?`, name).Scan(&holderPID)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// free
	case err != nil:
		return err
	case holderPID == pid:
		return nil // already ours
	case processAlive(holderPID):
		return fmt.Errorf("%w (pid %d)", ErrLockHeld, holderPID)
	}

	if _, err := tx.Exec(`
INSERT INTO locks (name, pid, acquired_at) VALUES (?, ?, strftime('%s','now'))
ON CONFLICT(name) DO UPDATE SET pid = excluded.pid, acquired_at = excluded.acquired_at
`, name, pid); err != nil {
		return err
	}

	return tx.Commit()
}

// ReleaseLock drops the lock if this process still holds it.
func (s *Store) ReleaseLock(name string) error {
	_, err := s.db.Exec(`DELETE FROM locks WHERE name = ? AND pid = ?`, name, os.Getpid())
	return err
}

// processAlive reports whether a PID is still running. Signal 0 performs
// the permission and existence checks without actually delivering anything.
//
// EPERM means the process exists but belongs to another user -- that is
// still alive. Treating it as dead would let us steal a lock from a live
// holder, which is exactly the case this lock exists to prevent.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = proc.Signal(syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}

// Plan inserts a pending row for the original, and for the edited render if
// the asset has adjustments, ignoring rows that already exist so re-running
// `plan` against a refreshed asset list never clobbers upload progress.
func (s *Store) Plan(rec asset.Record) error {
	versions := []asset.Version{asset.VersionOriginal}
	if rec.HasAdjustments {
		versions = append(versions, asset.VersionEdited)
	}

	for _, v := range versions {
		_, err := s.db.Exec(`
INSERT INTO assets (local_identifier, version, original_filename, creation_date, status)
VALUES (?, ?, ?, ?, 'pending')
ON CONFLICT(local_identifier, version) DO UPDATE SET
	original_filename = excluded.original_filename,
	creation_date = excluded.creation_date
`, rec.LocalIdentifier, string(v), rec.OriginalFilename, rec.CreationDate)
		if err != nil {
			return fmt.Errorf("plan %s/%s: %w", rec.LocalIdentifier, v, err)
		}
	}
	return nil
}

type PendingItem struct {
	LocalIdentifier  string
	Version          asset.Version
	CreationDate     float64
	OriginalFilename string
}

func (s *Store) Pending(limit int) ([]PendingItem, error) {
	return s.queryPending(`
SELECT local_identifier, version, creation_date, original_filename FROM assets
WHERE status = ?
ORDER BY creation_date ASC
LIMIT ?`, StatusPending, limit)
}

// PendingOriginals returns pending items of version=original with a known
// creation_date, for matching against Proton Photos' captureTime.
func (s *Store) PendingOriginals() ([]PendingItem, error) {
	return s.queryPending(`
SELECT local_identifier, version, creation_date, original_filename FROM assets
WHERE status = ? AND version = 'original' AND creation_date IS NOT NULL
ORDER BY creation_date ASC`, StatusPending)
}

func (s *Store) queryPending(query string, args ...any) ([]PendingItem, error) {
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []PendingItem
	for rows.Next() {
		var it PendingItem
		var v string
		var filename sql.NullString
		if err := rows.Scan(&it.LocalIdentifier, &v, &it.CreationDate, &filename); err != nil {
			return nil, err
		}
		it.Version = asset.Version(v)
		it.OriginalFilename = filename.String
		items = append(items, it)
	}
	return items, rows.Err()
}

func (s *Store) MarkUploaded(localIdentifier string, version asset.Version, contentHash, protonLinkID string, hasThumbnails bool) error {
	_, err := s.db.Exec(`
UPDATE assets SET status = ?, content_hash = ?, proton_link_id = ?, has_thumbnails = ?, last_attempt_at = strftime('%s','now'), error = NULL
WHERE local_identifier = ? AND version = ?`,
		StatusUploaded, contentHash, protonLinkID, hasThumbnails, localIdentifier, string(version))
	return err
}

// NeedsThumbnails lists photos we uploaded without previews. They keep
// their existing link -- re-uploading under the same name creates a new
// revision on it rather than a duplicate photo.
func (s *Store) NeedsThumbnails(limit int) ([]PendingItem, error) {
	return s.queryPending(`
SELECT local_identifier, version, creation_date, original_filename FROM assets
WHERE status = ? AND has_thumbnails = 0
ORDER BY creation_date ASC
LIMIT ?`, StatusUploaded, limit)
}

// MarkThumbnailed records that a photo now has its previews, without
// otherwise disturbing its row.
func (s *Store) MarkThumbnailed(localIdentifier string, version asset.Version) error {
	_, err := s.db.Exec(`
UPDATE assets SET has_thumbnails = 1, last_attempt_at = strftime('%s','now'), error = NULL
WHERE local_identifier = ? AND version = ?`, localIdentifier, string(version))
	return err
}

func (s *Store) MarkSkippedDuplicate(localIdentifier string, version asset.Version, contentHash string) error {
	_, err := s.db.Exec(`
UPDATE assets SET status = ?, content_hash = ?, last_attempt_at = strftime('%s','now'), error = NULL
WHERE local_identifier = ? AND version = ?`,
		StatusSkippedDuplicate, contentHash, localIdentifier, string(version))
	return err
}

func (s *Store) MarkFailed(localIdentifier string, version asset.Version, errMsg string) error {
	_, err := s.db.Exec(`
UPDATE assets SET status = ?, last_attempt_at = strftime('%s','now'), error = ?
WHERE local_identifier = ? AND version = ?`,
		StatusFailed, errMsg, localIdentifier, string(version))
	return err
}

type Counts struct {
	Pending, Uploaded, SkippedDuplicate, Failed int
}

func (s *Store) Counts() (Counts, error) {
	var c Counts
	rows, err := s.db.Query(`SELECT status, COUNT(*) FROM assets GROUP BY status`)
	if err != nil {
		return c, err
	}
	defer rows.Close()
	for rows.Next() {
		var status string
		var n int
		if err := rows.Scan(&status, &n); err != nil {
			return c, err
		}
		switch Status(status) {
		case StatusPending:
			c.Pending = n
		case StatusUploaded:
			c.Uploaded = n
		case StatusSkippedDuplicate:
			c.SkippedDuplicate = n
		case StatusFailed:
			c.Failed = n
		}
	}
	return c, rows.Err()
}
