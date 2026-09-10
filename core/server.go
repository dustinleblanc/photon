package core

import (
	"encoding/json"
	"errors"
	"io"
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

	// onSession, if set, is invoked after login/resume so the caller can
	// persist the (possibly rotated) session.
	onSession func(proton.Session) error
}

// NewServer returns an unauthenticated server. Seed an existing session with
// SetSession, or let the UI call POST /api/v1/auth/login.
func NewServer(onSession func(proton.Session) error) *Server {
	return &Server{onSession: onSession}
}

// SetSession seeds an already-resumed client + session (e.g. from a session
// the CLI read off disk at startup).
func (s *Server) SetSession(client *Client, session proton.Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.client = client
	s.session = session
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
	return mux
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
	Status    string   `json:"status"` // "ok" | "hv_required"
	HVToken   string   `json:"hvToken,omitempty"`
	HVMethods []string `json:"hvMethods,omitempty"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}

	client, session, err := Login(r.Context(), req.Username, req.Password, req.Totp, req.HVToken, req.HVMethod)
	if err != nil {
		var hv *proton.HVRequiredError
		if errors.As(err, &hv) {
			writeJSON(w, http.StatusOK, loginResponse{
				Status:    "hv_required",
				HVToken:   hv.Challenge.Token,
				HVMethods: hv.Challenge.Methods,
			})
			return
		}
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}

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

	rc, size, err := client.OpenOriginal(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	defer rc.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	if size > 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	}
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
