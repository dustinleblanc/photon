package core

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"photon/proton"
)// memTagsStore is an in-memory TagsStore for handler tests.
type memTagsStore struct {
	mu   sync.Mutex
	data []byte
}

func (m *memTagsStore) Load(context.Context) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.data == nil {
		return nil, ErrNoTags
	}
	return bytes.Clone(m.data), nil
}

func (m *memTagsStore) Save(_ context.Context, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.data = bytes.Clone(data)
	return nil
}

func tagsTestServer(t *testing.T) (*Server, *memTagsStore) {
	t.Helper()
	s := NewServer(nil)
	// The in-memory store never touches Drive; stub the resolver so the
	// bare test client doesn't try to open one.
	s.driveFor = func(context.Context, *Client) (*proton.Drive, error) {
		return nil, nil
	}
	store := &memTagsStore{}
	s.SetTagsStore(store)
	s.SetSession(&Client{}, proton.Session{})
	return s, store
}

func doTags(t *testing.T, s *Server, method, body string) (*httptest.ResponseRecorder, TagsDocument) {
	t.Helper()
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(method, "/api/v1/tags", nil)
	} else {
		req = httptest.NewRequest(method, "/api/v1/tags", bytes.NewBufferString(body))
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	var doc TagsDocument
	_ = json.Unmarshal(rec.Body.Bytes(), &doc)
	return rec, doc
}

func TestTagsGetEmpty(t *testing.T) {
	s, _ := tagsTestServer(t)
	rec, doc := doTags(t, s, "GET", "")
	if rec.Code != 200 {
		t.Fatalf("GET status = %d, want 200", rec.Code)
	}
	if doc.Revision != 0 || len(doc.Identities) != 0 {
		t.Fatalf("empty GET returned %+v", doc)
	}
}

func TestTagsPutBumpsRevision(t *testing.T) {
	s, _ := tagsTestServer(t)
	body := `{"baseRevision":0,"identities":[{"name":"Mom","centroid":[1,2,3],"samples":2}]}`
	rec, _ := doTags(t, s, "PUT", body)
	if rec.Code != 200 {
		t.Fatalf("PUT status = %d: %s", rec.Code, rec.Body.String())
	}

	rec, doc := doTags(t, s, "GET", "")
	if rec.Code != 200 || doc.Revision != 1 || len(doc.Identities) != 1 || doc.Identities[0].Name != "Mom" {
		t.Fatalf("after PUT: code=%d doc=%+v", rec.Code, doc)
	}
}

func TestTagsPutConflictReturnsCurrent(t *testing.T) {
	s, _ := tagsTestServer(t)
	if rec, _ := doTags(t, s, "PUT", `{"baseRevision":0,"identities":[]}`); rec.Code != 200 {
		t.Fatalf("first PUT status = %d", rec.Code)
	}
	rec, doc := doTags(t, s, "PUT", `{"baseRevision":0,"identities":[{"name":"Stale"}]}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("stale PUT status = %d, want 409", rec.Code)
	}
	if doc.Revision != 1 || len(doc.Identities) != 0 {
		t.Fatalf("conflict body should carry current doc, got %+v", doc)
	}
}

func TestTagsUnauthenticated(t *testing.T) {
	s := NewServer(nil)
	req := httptest.NewRequest("GET", "/api/v1/tags", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated GET status = %d, want 401", rec.Code)
	}
}
