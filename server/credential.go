// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"
)

// hashSecret returns the stored form of a token or password.
// Only this hash is written to the center config. The raw value is not.
func hashSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func hashEqual(stored, secret string) bool {
	stored = strings.TrimSpace(stored)
	want := hashSecret(secret)
	if len(stored) != len(want) {
		subtle.ConstantTimeCompare([]byte(want), []byte(want))
		return false
	}
	return subtle.ConstantTimeCompare([]byte(stored), []byte(want)) == 1
}

func randomToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// mintCredential signs a short-lived node credential. It is not the node's
// long-lived token. The payload is the server id and an expiry, nothing else.
func mintCredential(serverID string, exp time.Time, key []byte) (string, error) {
	if len(key) == 0 {
		return "", errors.New("missing center key")
	}
	if !validServerID(serverID) {
		return "", errors.New("bad server id")
	}
	payload := serverID + "|" + strconv.FormatInt(exp.Unix(), 10)
	enc := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(enc))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return "nq1." + enc + "." + sig, nil
}

func verifyCredential(token string, key []byte, serverID string, now time.Time) bool {
	if len(key) == 0 || !validServerID(serverID) || token == "" {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != "nq1" || parts[1] == "" || parts[2] == "" {
		return false
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(parts[1]))
	expected := mac.Sum(nil)
	got, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	if !hmac.Equal(expected, got) {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	id, expText, ok := strings.Cut(string(raw), "|")
	if !ok || id != serverID {
		return false
	}
	expUnix, err := strconv.ParseInt(expText, 10, 64)
	if err != nil {
		return false
	}
	exp := time.Unix(expUnix, 0)
	return now.Before(exp)
}

func validServerID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '.' || r == '_' || r == '-':
		default:
			return false
		}
	}
	return true
}
