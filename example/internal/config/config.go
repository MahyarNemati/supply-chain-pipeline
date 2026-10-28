// Package config loads and validates service configuration from the environment.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"
)

// Config is the validated runtime configuration of the service.
type Config struct {
	Addr            string
	LogLevel        slog.Level
	MaxBodyBytes    int64
	ShutdownTimeout time.Duration
}

const (
	defaultPort            = 8080
	defaultMaxBodyBytes    = 1 << 20
	defaultShutdownTimeout = 10 * time.Second
	maxAllowedBodyBytes    = 64 << 20
)

// Load reads configuration using getenv, which is os.Getenv in production and a
// map lookup in tests. All problems are reported together.
func Load(getenv func(string) string) (Config, error) {
	cfg := Config{
		Addr:            fmt.Sprintf(":%d", defaultPort),
		LogLevel:        slog.LevelInfo,
		MaxBodyBytes:    defaultMaxBodyBytes,
		ShutdownTimeout: defaultShutdownTimeout,
	}
	var errs []error

	if v := getenv("PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			errs = append(errs, fmt.Errorf("PORT: must be an integer in 1..65535, got %q", v))
		} else {
			cfg.Addr = fmt.Sprintf(":%d", p)
		}
	}

	if v := getenv("LOG_LEVEL"); v != "" {
		if err := cfg.LogLevel.UnmarshalText([]byte(strings.ToUpper(v))); err != nil {
			errs = append(errs, fmt.Errorf("LOG_LEVEL: %w", err))
		}
	}

	if v := getenv("MAX_BODY_BYTES"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 || n > maxAllowedBodyBytes {
			errs = append(errs, fmt.Errorf("MAX_BODY_BYTES: must be an integer in 1..%d, got %q", maxAllowedBodyBytes, v))
		} else {
			cfg.MaxBodyBytes = n
		}
	}

	if v := getenv("SHUTDOWN_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			errs = append(errs, fmt.Errorf("SHUTDOWN_TIMEOUT: must be a positive duration, got %q", v))
		} else {
			cfg.ShutdownTimeout = d
		}
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}
