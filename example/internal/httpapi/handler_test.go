package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := httptest.NewServer(New(log, BuildInfo{Version: "1.2.3", Commit: "abc123", Date: "2026-01-01T00:00:00Z"}, 16))
	t.Cleanup(srv.Close)
	return srv
}

func TestDigest(t *testing.T) {
	srv := newTestServer(t)

	tests := []struct {
		name       string
		query      string
		body       string
		wantStatus int
		wantDigest string
	}{
		{
			name:       "default sha256",
			body:       "hello",
			wantStatus: http.StatusOK,
			wantDigest: "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
		},
		{
			name:       "sha512",
			query:      "?alg=sha512",
			body:       "",
			wantStatus: http.StatusOK,
			wantDigest: "sha512:cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
		},
		{name: "unknown algorithm", query: "?alg=md5", body: "x", wantStatus: http.StatusBadRequest},
		{name: "body over limit", body: strings.Repeat("a", 17), wantStatus: http.StatusRequestEntityTooLarge},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := http.Post(srv.URL+"/v1/digest"+tc.query, "application/octet-stream", strings.NewReader(tc.body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.wantStatus)
			}
			if tc.wantDigest == "" {
				return
			}
			var got DigestResponse
			if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			if got.Digest != tc.wantDigest {
				t.Errorf("digest = %s, want %s", got.Digest, tc.wantDigest)
			}
			if got.Size != int64(len(tc.body)) {
				t.Errorf("size = %d, want %d", got.Size, len(tc.body))
			}
		})
	}
}

func TestVersionAndHealth(t *testing.T) {
	srv := newTestServer(t)

	resp, err := http.Get(srv.URL + "/version")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var bi BuildInfo
	if err := json.NewDecoder(resp.Body).Decode(&bi); err != nil {
		t.Fatal(err)
	}
	if bi.Version != "1.2.3" || bi.Commit != "abc123" {
		t.Errorf("unexpected build info: %+v", bi)
	}

	hr, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer hr.Body.Close()
	if hr.StatusCode != http.StatusOK {
		t.Errorf("healthz status = %d", hr.StatusCode)
	}
}

func TestMethodNotAllowed(t *testing.T) {
	srv := newTestServer(t)
	resp, err := http.Get(srv.URL + "/v1/digest")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("status = %d, want 405", resp.StatusCode)
	}
}
