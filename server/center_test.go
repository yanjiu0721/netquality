// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCredentialRoundTrip(t *testing.T) {
	key := []byte("example-center-key")
	exp := time.Now().Add(time.Minute)
	token, err := mintCredential("lab-node", exp, key)
	if err != nil {
		t.Fatal(err)
	}
	if !verifyCredential(token, key, "lab-node", time.Now()) {
		t.Fatal("fresh credential rejected")
	}
	if verifyCredential(token, key, "other", time.Now()) {
		t.Fatal("wrong server accepted")
	}
	if verifyCredential(token, []byte("other-key"), "lab-node", time.Now()) {
		t.Fatal("wrong key accepted")
	}
	old, err := mintCredential("lab-node", time.Now().Add(-time.Second), key)
	if err != nil {
		t.Fatal(err)
	}
	if verifyCredential(old, key, "lab-node", time.Now()) {
		t.Fatal("expired credential accepted")
	}
	if hashEqual("example-token", "example-token") {
		t.Fatal("raw secret was accepted as a stored hash")
	}
	if !hashEqual(hashSecret("example-token"), "example-token") {
		t.Fatal("hash mismatch")
	}
}

func TestCenterGroupsAndConfidentialProxy(t *testing.T) {
	const nodeToken = "super-secret-node-token"
	const hiddenHost = "secret-node.internal"
	node := newNode(nodeToken, true, nil, testLimits())
	node.ServerID = "lab-node"
	node.CenterKey = []byte("center-key")
	nodeSrv := httptest.NewServer(node.Handler())
	defer nodeSrv.Close()
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer page.Close()

	dir := t.TempDir()
	writeCenterFixture(t, dir, nodeSrv.URL, "https://"+hiddenHost+":8443", nodeToken, "center-key")
	mustWrite(t, filepath.Join(dir, "servers", "addr.json"), `{
		"id":"addr-node","name":"带地址的保密节点","controlUrl":"https://203.0.113.55:8443","groups":["lab"],"confidential":true,"nodeToken":"`+nodeToken+`"
	}`)
	center := newCenter(dir, "center-key")
	api := httptest.NewServer(center.Handler())
	defer api.Close()

	catalog := centerGET(t, api.URL+"/v1/center/catalog", "lab-token")
	raw, _ := io.ReadAll(catalog.Body)
	catalog.Body.Close()
	if catalog.StatusCode != http.StatusOK {
		t.Fatalf("catalog %d %s", catalog.StatusCode, raw)
	}
	body := string(raw)
	if strings.Contains(body, hiddenHost) || strings.Contains(body, nodeToken) || strings.Contains(body, "203.0.113.55") {
		t.Fatalf("catalog leaked a hidden address or token: %s", body)
	}
	var parsed struct {
		Group   string `json:"group"`
		Servers []struct {
			ID           string `json:"id"`
			Name         string `json:"name"`
			Confidential bool   `json:"confidential"`
			ControlURL   string `json:"controlUrl"`
			Credential   string `json:"credential"`
		} `json:"servers"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed.Group != "lab" || len(parsed.Servers) != 4 {
		t.Fatalf("parsed %+v", parsed)
	}
	var publicCred, secretName string
	for _, srv := range parsed.Servers {
		if srv.Confidential {
			secretName = srv.Name
			if srv.ControlURL != "" || srv.Credential != "" {
				t.Fatalf("confidential item %+v", srv)
			}
			continue
		}
		if srv.ControlURL != nodeSrv.URL || srv.Credential == "" || srv.Credential == nodeToken {
			t.Fatalf("public item %+v", srv)
		}
		publicCred = srv.Credential
	}
	if secretName != "保密节点" || publicCred == "" {
		t.Fatalf("names %+v", parsed.Servers)
	}
	if !verifyCredential(publicCred, node.CenterKey, "lab-node", time.Now()) {
		t.Fatal("catalog credential is not accepted by the node key")
	}
	direct := postJSON(t, nodeSrv.URL+"/v1/jobs", `{"target":"127.0.0.1","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":200,"durationSec":1}`)
	direct.Body.Close()
	req, _ := http.NewRequest(http.MethodPost, nodeSrv.URL+"/v1/jobs", strings.NewReader(`{"target":"127.0.0.1","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":200,"durationSec":1}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+publicCred)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if direct.StatusCode != http.StatusUnauthorized || res.StatusCode != http.StatusCreated {
		t.Fatalf("direct %d credential %d", direct.StatusCode, res.StatusCode)
	}

	other := centerGET(t, api.URL+"/v1/center/catalog", "ops-token")
	otherRaw, _ := io.ReadAll(other.Body)
	other.Body.Close()
	if other.StatusCode != http.StatusOK || strings.Contains(string(otherRaw), "实验室节点") || strings.Contains(string(otherRaw), hiddenHost) {
		t.Fatalf("other group %d %s", other.StatusCode, otherRaw)
	}

	denied := centerPOST(t, api.URL+"/v1/center/servers/secret-node/jobs", "ops-token", `{"target":"127.0.0.1","port":1,"profile":"tcp-connect","intervalMs":200,"timeoutMs":200,"durationSec":1}`)
	deniedRaw, _ := io.ReadAll(denied.Body)
	denied.Body.Close()
	if denied.StatusCode != http.StatusForbidden || strings.Contains(string(deniedRaw), hiddenHost) || strings.Contains(string(deniedRaw), nodeToken) {
		t.Fatalf("denied %d %s", denied.StatusCode, deniedRaw)
	}

	jobBody := `{"target":"` + page.URL + `/","port":` + page.URL[strings.LastIndex(page.URL, ":")+1:] + `,"profile":"http","intervalMs":200,"timeoutMs":1500,"durationSec":2,"allowIPv4":true,"allowIPv6":false,"http":{"version":"1.1","method":"GET"}}`
	created := centerPOST(t, api.URL+"/v1/center/servers/secret-node/jobs", "lab-token", jobBody)
	createdRaw, _ := io.ReadAll(created.Body)
	created.Body.Close()
	if created.StatusCode != http.StatusCreated || strings.Contains(string(createdRaw), hiddenHost) || strings.Contains(string(createdRaw), nodeToken) {
		t.Fatalf("proxy create %d %s", created.StatusCode, createdRaw)
	}
	var job struct {
		JobID string `json:"jobId"`
	}
	if err := json.Unmarshal(createdRaw, &job); err != nil {
		t.Fatal(err)
	}
	streamReq, _ := http.NewRequest(http.MethodGet, api.URL+"/v1/center/servers/secret-node/jobs/"+job.JobID+"/stream", nil)
	streamReq.Header.Set("Authorization", "Bearer lab-token")
	stream, err := http.DefaultClient.Do(streamReq)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	sample := readSSEMap(t, stream.Body)
	if sample["status"] != "ok" {
		t.Fatalf("proxied sample %+v", sample)
	}
	note, _ := sample["note"].(string)
	if !strings.Contains(note, "不是丢包") {
		t.Fatalf("note %s", note)
	}

	login := centerPOST(t, api.URL+"/v1/center/login", "", `{"account":"lab","password":"example-password"}`)
	loginRaw, _ := io.ReadAll(login.Body)
	login.Body.Close()
	if login.StatusCode != http.StatusOK || strings.Contains(string(loginRaw), "example-password") {
		t.Fatalf("login %d %s", login.StatusCode, loginRaw)
	}
	var session map[string]string
	if err := json.Unmarshal(loginRaw, &session); err != nil {
		t.Fatal(err)
	}
	if session["token"] == "" || session["token"] == "lab-token" {
		t.Fatalf("session %+v", session)
	}
	again := centerGET(t, api.URL+"/v1/center/catalog", session["token"])
	againRaw, _ := io.ReadAll(again.Body)
	again.Body.Close()
	if again.StatusCode != http.StatusOK || strings.Contains(string(againRaw), hiddenHost) {
		t.Fatalf("session catalog %d %s", again.StatusCode, againRaw)
	}
	stored, err := os.ReadFile(filepath.Join(dir, "tokens.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(stored), "lab-token") || strings.Contains(string(stored), "example-password") {
		t.Fatalf("token file stored a raw secret: %s", stored)
	}
}

func TestExampleCenterLoads(t *testing.T) {
	center := newCenter("example-center", "")
	key, err := loadCenterKeyFile("example-center")
	if err != nil || key == "" {
		t.Fatal(err, key)
	}
	center.Key = []byte(key)
	if _, err := center.load(); err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer(center.Handler())
	defer api.Close()
	res := centerGET(t, api.URL+"/v1/center/catalog", "example-token")
	raw, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("example catalog %d %s", res.StatusCode, raw)
	}
	if strings.Contains(string(raw), "secret-node.internal") || strings.Contains(string(raw), "example-secret-node-token") || strings.Contains(string(raw), "example-node-token") {
		t.Fatalf("example catalog leaked: %s", raw)
	}
	if !strings.Contains(string(raw), "实验室节点") || !strings.Contains(string(raw), "保密节点") {
		t.Fatalf("example catalog %s", raw)
	}
}

func writeCenterFixture(t *testing.T, dir, publicURL, secretURL, nodeToken, key string) {
	t.Helper()
	mustWrite(t, filepath.Join(dir, "groups.json"), `{"groups":[{"id":"lab","name":"实验室"},{"id":"ops","name":"另一组"}]}`)
	mustWrite(t, filepath.Join(dir, "tokens.json"), `{"tokens":[`+
		`{"id":"lab-reader","group":"lab","account":"lab","tokenHash":"`+hashSecret("lab-token")+`","passwordHash":"`+hashSecret("example-password")+`"},`+
		`{"id":"ops-reader","group":"ops","account":"ops","tokenHash":"`+hashSecret("ops-token")+`"}`+
		`]}`)
	if err := os.MkdirAll(filepath.Join(dir, "servers"), 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(dir, "servers", "lab.json"), `{
		"id":"lab-node","name":"实验室节点","controlUrl":"`+publicURL+`","groups":["lab"],"confidential":false,"nodeToken":"`+nodeToken+`"
	}`)
	mustWrite(t, filepath.Join(dir, "servers", "secret.json"), `{
		"id":"secret-node","name":"保密节点","controlUrl":"`+publicURL+`","groups":["lab"],"confidential":true,"nodeToken":"`+nodeToken+`"
	}`)
	mustWrite(t, filepath.Join(dir, "servers", "hidden.json"), `{
		"id":"hidden-node","name":"另一台保密节点","controlUrl":"`+secretURL+`","groups":["lab"],"confidential":true,"nodeToken":"`+nodeToken+`"
	}`)
	mustWrite(t, filepath.Join(dir, "center.key"), key+"\n")
}

func centerGET(t *testing.T, rawURL, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func centerPOST(t *testing.T, rawURL, token, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, rawURL, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func readSSEMap(t *testing.T, r io.Reader) map[string]any {
	t.Helper()
	sc := bufio.NewScanner(r)
	var data string
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
		if line == "" && data != "" && data != "{}" {
			var msg map[string]any
			if err := json.Unmarshal([]byte(data), &msg); err != nil {
				t.Fatal(err)
			}
			if status, _ := msg["status"].(string); status != "" && status != "pending" {
				return msg
			}
			data = ""
		}
	}
	t.Fatalf("no sample: %v", sc.Err())
	return nil
}
