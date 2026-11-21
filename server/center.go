// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	centerSessionTTL = 12 * time.Hour
	centerCredTTL    = 15 * time.Minute
)

type centerGroup struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type centerToken struct {
	ID           string `json:"id"`
	Group        string `json:"group"`
	Account      string `json:"account"`
	TokenHash    string `json:"tokenHash"`
	PasswordHash string `json:"passwordHash"`
}

type centerServer struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	ControlURL   string   `json:"controlUrl"`
	Groups       []string `json:"groups"`
	Confidential bool     `json:"confidential"`
	NodeToken    string   `json:"nodeToken"`
}

type centerConfig struct {
	groups  []centerGroup
	tokens  []centerToken
	servers []centerServer
}

type centerSession struct {
	group   string
	account string
	exp     time.Time
}

// Center is the same process as the probe node, serving a directory of
// groups, token hashes and servers. Confidential nodes are proxied.
// Their addresses are not included in catalog responses.
type Center struct {
	Dir string
	Key []byte

	mu       sync.Mutex
	sessions map[string]centerSession
	client   *http.Client
}

func newCenter(dir string, key string) *Center {
	c := &Center{
		Dir:      dir,
		sessions: map[string]centerSession{},
		client: &http.Client{
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
	if strings.TrimSpace(key) != "" {
		c.Key = []byte(strings.TrimSpace(key))
	}
	return c
}

func (c *Center) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/center/login", c.login)
	mux.HandleFunc("GET /v1/center/catalog", c.catalog)
	mux.HandleFunc("POST /v1/center/servers/{id}/jobs", c.proxyCreate)
	mux.HandleFunc("GET /v1/center/servers/{id}/jobs/{jobId}", c.proxySnapshot)
	mux.HandleFunc("GET /v1/center/servers/{id}/jobs/{jobId}/stream", c.proxyStream)
	mux.HandleFunc("DELETE /v1/center/servers/{id}/jobs/{jobId}", c.proxyDelete)
	return mux
}

type catalogServer struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	Confidential        bool   `json:"confidential"`
	ControlURL          string `json:"controlUrl,omitempty"`
	Credential          string `json:"credential,omitempty"`
	CredentialExpiresAt string `json:"credentialExpiresAt,omitempty"`
}

func (c *Center) login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Account  string `json:"account"`
		Password string `json:"password"`
	}
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<16))
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "请求内容无法解析")
		return
	}
	cfg, err := c.load()
	if err != nil {
		log.Printf("center config: %v", err)
		writeErr(w, http.StatusInternalServerError, "config", "中心配置无法读取")
		return
	}
	account := strings.TrimSpace(req.Account)
	var matched *centerToken
	for i := range cfg.tokens {
		tok := &cfg.tokens[i]
		if tok.Account != account || tok.PasswordHash == "" {
			continue
		}
		if hashEqual(tok.PasswordHash, req.Password) && c.groupKnown(cfg, tok.Group) {
			matched = tok
			break
		}
	}
	if matched == nil {
		log.Printf("center login failed")
		writeErr(w, http.StatusUnauthorized, "unauthorized", "账号或密码不正确")
		return
	}
	raw, err := randomToken()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "error", "暂时无法登录")
		return
	}
	exp := time.Now().Add(centerSessionTTL)
	c.mu.Lock()
	c.sessions[hashSecret(raw)] = centerSession{group: matched.Group, account: matched.Account, exp: exp}
	c.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{
		"token":     raw,
		"account":   matched.Account,
		"group":     matched.Group,
		"expiresAt": exp.UTC().Format(time.RFC3339),
	})
}

func (c *Center) catalog(w http.ResponseWriter, r *http.Request) {
	group, account, ok := c.who(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "中心口令不正确或未提供")
		return
	}
	cfg, err := c.load()
	if err != nil {
		log.Printf("center config: %v", err)
		writeErr(w, http.StatusInternalServerError, "config", "中心配置无法读取")
		return
	}
	items := make([]catalogServer, 0)
	for _, srv := range cfg.servers {
		if !containsString(srv.Groups, group) {
			continue
		}
		item := catalogServer{ID: srv.ID, Name: srv.Name, Confidential: srv.Confidential}
		if srv.Confidential {
			items = append(items, item)
			continue
		}
		if len(c.Key) == 0 {
			writeErr(w, http.StatusInternalServerError, "config", "中心没有 center.key，不能给非保密节点签发短期凭证")
			return
		}
		exp := time.Now().Add(centerCredTTL)
		cred, err := mintCredential(srv.ID, exp, c.Key)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "config", "无法签发短期凭证")
			return
		}
		item.ControlURL = srv.ControlURL
		item.Credential = cred
		item.CredentialExpiresAt = exp.UTC().Format(time.RFC3339)
		items = append(items, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account": account,
		"group":   group,
		"servers": items,
	})
}

func (c *Center) proxyCreate(w http.ResponseWriter, r *http.Request) {
	c.proxy(w, r, "/v1/jobs")
}

func (c *Center) proxySnapshot(w http.ResponseWriter, r *http.Request) {
	c.proxy(w, r, "/v1/jobs/"+url.PathEscape(r.PathValue("jobId")))
}

func (c *Center) proxyStream(w http.ResponseWriter, r *http.Request) {
	c.proxy(w, r, "/v1/jobs/"+url.PathEscape(r.PathValue("jobId"))+"/stream")
}

func (c *Center) proxyDelete(w http.ResponseWriter, r *http.Request) {
	c.proxy(w, r, "/v1/jobs/"+url.PathEscape(r.PathValue("jobId")))
}

func (c *Center) proxy(w http.ResponseWriter, r *http.Request, path string) {
	srv, ok := c.authorizedServer(w, r)
	if !ok {
		return
	}
	base, err := url.Parse(srv.ControlURL)
	if err != nil || base.Host == "" {
		writeErr(w, http.StatusBadGateway, "node", "连不上节点")
		return
	}
	target := base.ResolveReference(&url.URL{Path: path})
	body := io.Reader(nil)
	if r.Body != nil && r.Method != http.MethodGet && r.Method != http.MethodDelete {
		body = io.LimitReader(r.Body, 1<<16)
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), body)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "node", "连不上节点")
		return
	}
	if srv.NodeToken != "" {
		req.Header.Set("Authorization", "Bearer "+srv.NodeToken)
	}
	if r.Header.Get("Content-Type") != "" {
		req.Header.Set("Content-Type", r.Header.Get("Content-Type"))
	}
	resp, err := c.client.Do(req)
	if err != nil {
		log.Printf("center proxy failed server=%s", srv.ID)
		writeErr(w, http.StatusBadGateway, "node", "连不上节点")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		writeErr(w, http.StatusBadGateway, "node", "节点地址发生了跳转")
		return
	}
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	if strings.Contains(resp.Header.Get("Content-Type"), "event-stream") {
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(resp.StatusCode)
		flusher, _ := w.(http.Flusher)
		buf := make([]byte, 32*1024)
		for {
			n, readErr := resp.Body.Read(buf)
			if n > 0 {
				if _, err := w.Write(buf[:n]); err != nil {
					return
				}
				if flusher != nil {
					flusher.Flush()
				}
			}
			if readErr != nil {
				return
			}
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (c *Center) authorizedServer(w http.ResponseWriter, r *http.Request) (centerServer, bool) {
	group, _, ok := c.who(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "中心口令不正确或未提供")
		return centerServer{}, false
	}
	cfg, err := c.load()
	if err != nil {
		log.Printf("center config: %v", err)
		writeErr(w, http.StatusInternalServerError, "config", "中心配置无法读取")
		return centerServer{}, false
	}
	id := r.PathValue("id")
	for _, srv := range cfg.servers {
		if srv.ID != id {
			continue
		}
		if !containsString(srv.Groups, group) {
			writeErr(w, http.StatusForbidden, "forbidden", "这个口令不能使用该服务器")
			return centerServer{}, false
		}
		return srv, true
	}
	writeErr(w, http.StatusNotFound, "not_found", "没有这台服务器")
	return centerServer{}, false
}

func (c *Center) who(r *http.Request) (string, string, bool) {
	raw := bearer(r.Header.Get("Authorization"))
	if raw == "" {
		return "", "", false
	}
	sum := hashSecret(raw)
	now := time.Now()
	c.mu.Lock()
	if s, ok := c.sessions[sum]; ok {
		if now.Before(s.exp) {
			c.mu.Unlock()
			return s.group, s.account, true
		}
		delete(c.sessions, sum)
	}
	c.mu.Unlock()
	cfg, err := c.load()
	if err != nil {
		log.Printf("center config: %v", err)
		return "", "", false
	}
	for _, tok := range cfg.tokens {
		if tok.TokenHash == "" || !c.groupKnown(cfg, tok.Group) {
			continue
		}
		if hashEqual(tok.TokenHash, raw) {
			return tok.Group, tok.Account, true
		}
	}
	return "", "", false
}

func (c *Center) groupKnown(cfg centerConfig, id string) bool {
	for _, g := range cfg.groups {
		if g.ID == id {
			return true
		}
	}
	return false
}

func (c *Center) load() (centerConfig, error) {
	var cfg centerConfig
	var groups struct {
		Groups []centerGroup `json:"groups"`
	}
	if err := readJSONFile(filepath.Join(c.Dir, "groups.json"), &groups); err != nil {
		return cfg, err
	}
	var tokens struct {
		Tokens []centerToken `json:"tokens"`
	}
	if err := readJSONFile(filepath.Join(c.Dir, "tokens.json"), &tokens); err != nil {
		return cfg, err
	}
	entries, err := os.ReadDir(filepath.Join(c.Dir, "servers"))
	if err != nil {
		return cfg, err
	}
	seen := map[string]struct{}{}
	var servers []centerServer
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		var srv centerServer
		if err := readJSONFile(filepath.Join(c.Dir, "servers", entry.Name()), &srv); err != nil {
			return cfg, err
		}
		if err := validateCenterServer(srv); err != nil {
			return cfg, err
		}
		if _, ok := seen[srv.ID]; ok {
			return cfg, fmt.Errorf("duplicate server id")
		}
		seen[srv.ID] = struct{}{}
		servers = append(servers, srv)
	}
	groupIDs := map[string]struct{}{}
	for _, g := range groups.Groups {
		if !validServerID(g.ID) {
			return cfg, fmt.Errorf("bad group id")
		}
		if _, ok := groupIDs[g.ID]; ok {
			return cfg, fmt.Errorf("duplicate group")
		}
		groupIDs[g.ID] = struct{}{}
	}
	for _, tok := range tokens.Tokens {
		if _, ok := groupIDs[tok.Group]; !ok {
			return cfg, fmt.Errorf("token group missing")
		}
		if !strings.HasPrefix(strings.TrimSpace(tok.TokenHash), "sha256:") {
			return cfg, fmt.Errorf("token hash missing")
		}
	}
	for _, srv := range servers {
		for _, g := range srv.Groups {
			if _, ok := groupIDs[g]; !ok {
				return cfg, fmt.Errorf("server group missing")
			}
		}
	}
	cfg.groups = groups.Groups
	cfg.tokens = tokens.Tokens
	cfg.servers = servers
	return cfg, nil
}

func validateCenterServer(srv centerServer) error {
	if !validServerID(srv.ID) || strings.TrimSpace(srv.Name) == "" {
		return fmt.Errorf("bad server")
	}
	u, err := url.Parse(strings.TrimSpace(srv.ControlURL))
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil {
		return fmt.Errorf("bad control url")
	}
	if len(srv.Groups) == 0 {
		return fmt.Errorf("server has no group")
	}
	return nil
}

func readJSONFile(path string, dest any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, 1<<20))
	if err := dec.Decode(dest); err != nil {
		return err
	}
	return nil
}

func containsString(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

func loadCenterKeyFile(dir string) (string, error) {
	if strings.TrimSpace(dir) == "" {
		return "", nil
	}
	b, err := os.ReadFile(filepath.Join(dir, "center.key"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return line, nil
	}
	return "", nil
}
