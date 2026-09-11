package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	"photon/proton"
)

// Server exposes the loopback HTTP API the Flutter UI consumes. It is bound to
// 127.0.0.1 only; the UI is expected to run on the same machine.
type Server struct {
	mu      sync.Mutex
	client  *Client
	session proton.Session
	tags    TagsStore

	// driveFor resolves the drive backing the tags store; swapped out in
	// tests so the in-memory store never touches the network.
	driveFor func(context.Context, *Client) (*proton.Drive, error)

	// onSession, if set, is invoked after login/resume so the caller can
	// persist the (possibly rotated) session.
	onSession func(proton.Session) error
}

// NewServer returns an unauthenticated server. Seed an existing session with
// SetSession, or let the UI call POST /api/v1/auth/login.
func NewServer(onSession func(proton.Session) error) *Server {
	s := &Server{onSession: onSession, tags: DriveTagsStore{}}
	s.driveFor = defaultDriveFor
	return s
}

// defaultDriveFor lazily opens the account's regular Drive for tags I/O.
func defaultDriveFor(ctx context.Context, client *Client) (*proton.Drive, error) {
	return client.FilesDrive(ctx)
}

// PersistSession exposes the session-persistence callback (used by cmdServe
// to keep the on-disk session fresh across token rotations from the very
// first request).
func (s *Server) PersistSession(session proton.Session) {
	s.persistSession(session)
}

// SetSession seeds an already-resumed client + session (e.g. from a session
// the CLI read off disk at startup).
func (s *Server) SetSession(client *Client, session proton.Session) {
	client.OnRotate(s.persistSession)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.client = client
	s.session = session
}

// SetTagsStore swaps the snapshot store (tests use an in-memory one).
func (s *Server) SetTagsStore(store TagsStore) {
	s.tags = store
}

// Handler builds the mux. Split out so tests can drive it without a listener.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("GET /api/v1/session", s.sessionStatus)
	mux.HandleFunc("POST /api/v1/auth/login", s.login)
	mux.HandleFunc("POST /api/v1/auth/logout", s.logout)
	mux.HandleFunc("GET /api/v1/assets", s.listAssets)
	mux.HandleFunc("GET /api/v1/assets/{id}/original", s.original)
	mux.HandleFunc("GET /api/v1/assets/{id}/preview", s.preview)
	mux.HandleFunc("GET /api/v1/tags", s.getTags)
	mux.HandleFunc("PUT /api/v1/tags", s.putTags)
	return logRequests(mux)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		slog.Info("http",
			"method", r.Method,
			"path", r.URL.Path,
			"query", r.URL.RawQuery,
			"remote", r.RemoteAddr,
			"status", rec.status,
		)
	})
}

// Serve blocks, serving on addr (default "127.0.0.1:8787").
func (s *Server) Serve(addr string) error {
	if addr == "" {
		addr = "127.0.0.1:8787"
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	return srv.ListenAndServe()
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) sessionStatus(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]bool{"authenticated": s.client != nil})
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Totp     string `json:"totp"`
	HVToken  string `json:"hvToken"`
	HVMethod string `json:"hvMethod"`
}

type loginResponse struct {
	Status    string   `json:"status"` // "ok" | "hv_required" | "totp_required"
	HVToken   string   `json:"hvToken,omitempty"`
	HVMethods []string `json:"hvMethods,omitempty"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}

	client, session, err := Login(r.Context(), req.Username, req.Password, req.Totp, req.HVToken, req.HVMethod, s.persistSession)
	if err != nil {
		var hv *proton.HVRequiredError
		switch {
		case errors.As(err, &hv):
			writeJSON(w, http.StatusOK, loginResponse{
				Status:    "hv_required",
				HVToken:   hv.Challenge.Token,
				HVMethods: hv.Challenge.Methods,
			})
			return
		case errors.Is(err, proton.ErrTotpRequired):
			writeJSON(w, http.StatusOK, loginResponse{Status: "totp_required"})
			return
		default:
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
	}

	client.OnRotate(s.persistSession)
	client.OnRotate(s.persistSession)
	s.mu.Lock()
	s.client = client
	s.session = session
	s.mu.Unlock()
	s.persistSession(session)

	writeJSON(w, http.StatusOK, loginResponse{Status: "ok"})
}

func (s *Server) logout(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.client = nil
	s.session = proton.Session{}
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) persistSession(session proton.Session) {
	if s.onSession != nil {
		_ = s.onSession(session)
	}
}

func (s *Server) currentClient() *Client {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.client
}

type assetsResponse struct {
	Assets     []Photo `json:"assets"`
	NextCursor string  `json:"nextCursor,omitempty"`
}

func (s *Server) listAssets(w http.ResponseWriter, r *http.Request) {
	client := s.currentClient()
	if client == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}

	cursor := r.URL.Query().Get("cursor")
	pageSize := 500
	if ps := r.URL.Query().Get("pageSize"); ps != "" {
		if n, err := strconv.Atoi(ps); err == nil && n > 0 {
			pageSize = n
		}
	}

	photos, err := client.ListPhotos(r.Context(), cursor, pageSize)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	resp := assetsResponse{Assets: photos}
	if len(photos) == pageSize {
		resp.NextCursor = photos[len(photos)-1].LinkID
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) original(w http.ResponseWriter, r *http.Request) {
	client := s.currentClient()
	if client == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}

	rc, _, err := client.OpenOriginal(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	defer rc.Close()

	// Note: no Content-Length here. DownloadFileByID reports the padded
	// encrypted size, which is larger than the decrypted bytes actually
	// streamed; a stale Content-Length makes strict clients (Dart's
	// HttpClient) fail with "connection closed while receiving data". Body is
	// delivered chunked, length inferred from the wire.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, rc)
}

func (s *Server) preview(w http.ResponseWriter, r *http.Request) {
	client := s.currentClient()
	if client == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}

	size := 512
	if sz := r.URL.Query().Get("size"); sz != "" {
		if n, err := strconv.Atoi(sz); err == nil && n > 0 {
			size = n
		}
	}

	data, err := client.FetchPreview(r.Context(), r.PathValue("id"), size)
	if errors.Is(err, ErrPreviewUnavailable) {
		writeError(w, http.StatusNotImplemented, "preview not available yet")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
