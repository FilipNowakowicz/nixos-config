package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

type whoisResponse struct {
	UserProfile *struct {
		LoginName   string `json:"LoginName"`
		DisplayName string `json:"DisplayName"`
	} `json:"UserProfile"`
}

func main() {
	listenAddr := envOrDefault("LISTEN_ADDR", "127.0.0.1:3180")
	tailscaleBin := envOrDefault("TAILSCALE_BIN", "tailscale")
	defaultRole := envOrDefault("DEFAULT_ROLE", "Viewer")

	roleMap := map[string]string{}
	if raw := os.Getenv("ROLE_MAP_JSON"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &roleMap); err != nil {
			log.Fatalf("parse ROLE_MAP_JSON: %v", err)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/auth", func(w http.ResponseWriter, r *http.Request) {
		remoteAddr := strings.TrimSpace(r.Header.Get("X-Tailscale-Remote-Addr"))
		if remoteAddr == "" {
			http.Error(w, "missing remote addr", http.StatusBadRequest)
			return
		}

		who, err := lookupWhois(r.Context(), tailscaleBin, remoteAddr)
		if err != nil {
			log.Printf("whois %q failed: %v", remoteAddr, err)
			http.Error(w, "tailscale identity lookup failed", http.StatusUnauthorized)
			return
		}
		if who.UserProfile == nil || strings.TrimSpace(who.UserProfile.LoginName) == "" {
			http.Error(w, "tagged devices do not get Grafana SSO", http.StatusForbidden)
			return
		}

		login := strings.TrimSpace(who.UserProfile.LoginName)
		name := strings.TrimSpace(who.UserProfile.DisplayName)
		if name == "" {
			name = login
		}

		role := defaultRole
		if mappedRole, ok := roleMap[login]; ok && mappedRole != "" {
			role = mappedRole
		}

		w.Header().Set("X-Auth-Request-User", login)
		w.Header().Set("X-Auth-Request-Email", login)
		w.Header().Set("X-Auth-Request-Name", name)
		w.Header().Set("X-Auth-Request-Role", role)
		w.WriteHeader(http.StatusNoContent)
	})

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("listening on %s", listenAddr)
	log.Fatal(server.ListenAndServe())
}

func lookupWhois(ctx context.Context, tailscaleBin, remoteAddr string) (*whoisResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, tailscaleBin, "whois", "--json", remoteAddr)
	output, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return nil, err
	}

	var who whoisResponse
	if err := json.Unmarshal(output, &who); err != nil {
		return nil, err
	}
	return &who, nil
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
