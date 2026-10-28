// Package httpapi exposes the digest service over HTTP.
package httpapi

import (
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// BuildInfo is stamped into the binary at link time.
type BuildInfo struct {
	Version string `json:"version"`
	Commit  string `json:"commit"`
	Date    string `json:"date"`
}

// DigestResponse is returned by POST /v1/digest.
type DigestResponse struct {
	Algorithm string `json:"algorithm"`
	Digest    string `json:"digest"`
	Size      int64  `json:"size"`
}

type errorResponse struct {
	Error string `json:"error"`
}

var hashers = map[string]func() hash.Hash{
	"sha256": sha256.New,
	"sha512": sha512.New,
}

// Handler serves the API.
type Handler struct {
	log          *slog.Logger
	build        BuildInfo
	maxBodyBytes int64
}

// New returns an http.Handler with all routes registered and request logging applied.
func New(log *slog.Logger, build BuildInfo, maxBodyBytes int64) http.Handler {
	h := &Handler{log: log, build: build, maxBodyBytes: maxBodyBytes}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.healthz)
	mux.HandleFunc("GET /version", h.version)
	mux.HandleFunc("POST /v1/digest", h.digest)
	return h.logRequests(mux)
}

func (h *Handler) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.build)
}

func (h *Handler) digest(w http.ResponseWriter, r *http.Request) {
	alg := r.URL.Query().Get("alg")
	if alg == "" {
		alg = "sha256"
	}
	newHash, ok := hashers[alg]
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "unsupported algorithm: " + alg})
		return
	}

	hs := newHash()
	n, err := io.Copy(hs, http.MaxBytesReader(w, r.Body, h.maxBodyBytes))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse{Error: "request body too large"})
			return
		}
		h.log.ErrorContext(r.Context(), "read body", "err", err)
		writeJSON(w, http.StatusBadRequest, errorResponse{Error: "could not read request body"})
		return
	}

	writeJSON(w, http.StatusOK, DigestResponse{
		Algorithm: alg,
		Digest:    alg + ":" + hex.EncodeToString(hs.Sum(nil)),
		Size:      n,
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (h *Handler) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		h.log.InfoContext(r.Context(), "request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
