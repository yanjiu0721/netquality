package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseDotEnv(t *testing.T) {
	src := "\uFEFF# 注释\r\n\r\n" +
		"NQ_BIND=127.0.0.1 # 只听本机\r\n" +
		"export NQ_MODE=node\r\n" +
		"NQ_TOKEN=\"a b # c\"\r\n" +
		"NQ_NODE_TOKEN='keep # this'\r\n" +
		"NQ_TCP_PORT=19090\r\n" +
		"NQ_VERBOSE=true\r\n" +
		"NQ_TOKEN=later\r\n"
	got, err := parseDotEnv(strings.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	if got["NQ_BIND"] != "127.0.0.1" || got["NQ_MODE"] != "node" {
		t.Fatalf("basic: %#v", got)
	}
	if got["NQ_TOKEN"] != "later" {
		t.Fatalf("last key wins, got %q", got["NQ_TOKEN"])
	}
	if got["NQ_NODE_TOKEN"] != "keep # this" {
		t.Fatalf("quotes: %q", got["NQ_NODE_TOKEN"])
	}
	if got["NQ_VERBOSE"] != "true" {
		t.Fatalf("verbose: %#v", got)
	}
}

func TestParseDotEnvErrors(t *testing.T) {
	cases := []string{
		"not a pair",
		"NQ_NOPE=1",
		"NQ_TOKEN=\"abc\" leftover",
		"NQ_TOKEN=\"unterminated",
		"1BAD=1",
	}
	for _, src := range cases {
		if _, err := parseDotEnv(strings.NewReader(src)); err == nil {
			t.Fatalf("expected error for %q", src)
		}
	}
}

func TestMissingEnvFileIsNotAnError(t *testing.T) {
	cfg, err := loadConfigAt(nil, nil, t.TempDir(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.LoadedFiles) != 0 {
		t.Fatalf("loaded %v", cfg.LoadedFiles)
	}
	if cfg.Bind != defaultBind || cfg.TCPPort != defaultTCPPort || cfg.UDPPort != defaultUDPPort || cfg.Mode != defaultMode || cfg.ControlAddr != defaultControlAddr {
		t.Fatalf("defaults: %+v", cfg)
	}
	if cfg.Token != "" || cfg.NodeToken != "" || cfg.AllowPrivate || cfg.Verbose || cfg.AllowNets != "" || cfg.TLSCert != "" || cfg.TLSKey != "" {
		t.Fatalf("empty defaults: %+v", cfg)
	}
}

func TestExplicitEnvMustExist(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.env")
	_, err := loadConfigAt([]string{"-env", missing}, nil, t.TempDir(), t.TempDir())
	if err == nil {
		t.Fatal("expected missing -env to fail")
	}
}

func TestEnvFilePrecedence(t *testing.T) {
	exe := t.TempDir()
	cwd := t.TempDir()
	explicit := filepath.Join(t.TempDir(), "custom.env")
	mustWrite(t, filepath.Join(exe, ".env"), "NQ_TCP_PORT=1111\nNQ_TOKEN=from-exe\nNQ_VERBOSE=true\n")
	mustWrite(t, filepath.Join(cwd, ".env"), "NQ_TCP_PORT=2222\nNQ_TOKEN=from-cwd\n")
	mustWrite(t, explicit, "NQ_TCP_PORT=3333\nNQ_TOKEN=from-explicit\n")

	cwdOnly, err := loadConfigAt(nil, nil, exe, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if cwdOnly.TCPPort != 2222 || cwdOnly.Token != "from-cwd" || !cwdOnly.Verbose {
		t.Fatalf("cwd should override exe dir and keep untouched keys: %+v", cwdOnly)
	}

	envWins, err := loadConfigAt(nil, []string{"NQ_TCP_PORT=4444", "NQ_TOKEN="}, exe, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if envWins.TCPPort != 4444 || envWins.Token != "" {
		t.Fatalf("real env should beat .env, including an empty value: %+v", envWins)
	}

	flagWins, err := loadConfigAt([]string{"-tcp-port", "5555", "-token", "from-flag"}, []string{"NQ_TCP_PORT=4444", "NQ_TOKEN=from-env"}, exe, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if flagWins.TCPPort != 5555 || flagWins.Token != "from-flag" {
		t.Fatalf("flags should beat env: %+v", flagWins)
	}

	fileWins, err := loadConfigAt([]string{"-env", explicit}, nil, exe, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if fileWins.TCPPort != 3333 || fileWins.Token != "from-explicit" {
		t.Fatalf("explicit -env should beat the other files: %+v", fileWins)
	}
	if !fileWins.Verbose {
		t.Fatal("key only present in the exe .env should remain")
	}
}

func TestBoolFlagBeatsFile(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, ".env"), "NQ_ALLOW_PRIVATE=true\nNQ_VERBOSE=yes\n")
	cfg, err := loadConfigAt([]string{"-allow-private=false", "-v=false"}, nil, dir, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AllowPrivate || cfg.Verbose {
		t.Fatalf("flags should force false: %+v", cfg)
	}
	fromFile, err := loadConfigAt(nil, nil, dir, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !fromFile.AllowPrivate || !fromFile.Verbose {
		t.Fatalf("file should set bools when flags are absent: %+v", fromFile)
	}
}

func TestConfigValidation(t *testing.T) {
	dir := t.TempDir()
	cases := []string{
		"NQ_TCP_PORT=nope\n",
		"NQ_MODE=sometimes\n",
		"NQ_TCP_PORT=0\nNQ_UDP_PORT=0\n",
		"NQ_TLS_CERT=/tmp/cert.pem\n",
		"NQ_TOKEN=" + strings.Repeat("a", 33) + "\n",
		"NQ_ALLOW_PRIVATE=maybe\n",
		"NQ_ALLOW_NETS=not-a-cidr\n",
	}
	for _, src := range cases {
		mustWrite(t, filepath.Join(dir, ".env"), src)
		if _, err := loadConfigAt(nil, nil, dir, t.TempDir()); err == nil {
			t.Fatalf("expected error for %q", src)
		}
	}
}

func TestSummaryMasksTokens(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, ".env"), "NQ_TOKEN=super-secret-echo\nNQ_NODE_TOKEN=super-secret-node\nNQ_MODE=both\n")
	cfg, err := loadConfigAt(nil, nil, dir, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	line := cfg.Summary()
	if strings.Contains(line, "super-secret") {
		t.Fatal(line)
	}
	if !strings.Contains(line, "echo_token=已设置") || !strings.Contains(line, "node_token=已设置") {
		t.Fatal(line)
	}
	plain, err := loadConfigAt(nil, nil, t.TempDir(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plain.Summary(), "echo_token=未设置") || !strings.Contains(plain.Summary(), "node_token=未设置") {
		t.Fatal(plain.Summary())
	}
}

func TestShippedEnvMatchesDefaults(t *testing.T) {
	base, err := loadConfigAt(nil, nil, t.TempDir(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".env", ".env.example"} {
		dir := t.TempDir()
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		mustWrite(t, filepath.Join(dir, ".env"), string(raw))
		cfg, err := loadConfigAt(nil, nil, dir, t.TempDir())
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if cfg.Bind != base.Bind || cfg.TCPPort != base.TCPPort || cfg.UDPPort != base.UDPPort ||
			cfg.Token != base.Token || cfg.NodeToken != base.NodeToken || cfg.Mode != base.Mode ||
			cfg.ControlAddr != base.ControlAddr || cfg.AllowPrivate != base.AllowPrivate ||
			cfg.AllowNets != base.AllowNets || cfg.TLSCert != base.TLSCert || cfg.TLSKey != base.TLSKey ||
			cfg.Verbose != base.Verbose {
			t.Fatalf("%s changed defaults:\n got %+v\nwant %+v", name, cfg, base)
		}
		parsed, err := parseDotEnv(strings.NewReader(string(raw)))
		if err != nil {
			t.Fatal(err)
		}
		if len(parsed) != len(knownEnvKeys) {
			t.Fatalf("%s documents %d keys, want %d", name, len(parsed), len(knownEnvKeys))
		}
	}
}

func TestHelp(t *testing.T) {
	_, err := loadConfigAt([]string{"-h"}, nil, t.TempDir(), t.TempDir())
	if err != errHelp {
		t.Fatalf("got %v", err)
	}
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}
