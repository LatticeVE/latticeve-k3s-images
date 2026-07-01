package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	mmdsBase              = "http://169.254.169.254"
	stateDir              = "/var/lib/latticeve"
	snapshotAttemptsDir   = stateDir + "/snapshot-attempts"
	lastUpgradeNonceFile  = stateDir + "/last-upgrade-nonce"
	lastSnapshotNonceFile = stateDir + "/last-snapshot-nonce"
	logPath               = "/var/log/latticeve-k3s-upgrade.log"
	snapshotDir           = "/var/lib/rancher/k3s/server/db/snapshots"
	controllerCAPath      = "/usr/local/share/ca-certificates/lattice-controller.crt"
)

var logMu sync.Mutex
var (
	mmdsToken        string
	mmdsTokenExpires time.Time
)

func main() {
	_ = os.MkdirAll(stateDir, 0755)
	_ = os.MkdirAll(snapshotAttemptsDir, 0755)
	_ = os.MkdirAll("/var/log", 0755)
	logf("latticeve-k3s-upgrade-watch started")

	client := &http.Client{Timeout: 5 * time.Second}
	for {
		// Upgrade requests are authoritative. A stale snapshot request must not
		// starve the upgrade path.
		if err := runUpgradeIfRequested(client); err != nil {
			logf("%s upgrade watch error: %v", now(), err)
		}
		if err := uploadSnapshotIfRequested(client); err != nil {
			logf("%s snapshot watch error: %v", now(), err)
		}
		time.Sleep(5 * time.Second)
	}
}

func runUpgradeIfRequested(client *http.Client) error {
	version := mmdsString(client, "upgrade_version")
	nonce := mmdsString(client, "upgrade_nonce")
	if version == "" || nonce == "" {
		return nil
	}
	last := strings.TrimSpace(readFile(lastUpgradeNonceFile))
	if nonce == last {
		return nil
	}

	logf("%s upgrade requested: version=%s nonce=%s", now(), version, nonce)
	_ = os.WriteFile(lastUpgradeNonceFile, []byte(nonce), 0644)
	out, err := runCommand("/usr/local/bin/latticeve-k3s-upgrade", version)
	appendLog(out)
	if err != nil {
		logf("%s upgrade failed: version=%s nonce=%s err=%v", now(), version, nonce, err)
		return nil
	}
	logf("%s upgrade completed: version=%s nonce=%s", now(), version, nonce)
	return nil
}

func uploadSnapshotIfRequested(client *http.Client) error {
	if mmdsString(client, "role") != "server" {
		return nil
	}
	snapshotURL := mmdsString(client, "snapshot_url")
	snapshotToken := mmdsString(client, "snapshot_token")
	snapshotName := mmdsString(client, "snapshot_name")
	snapshotReason := mmdsString(client, "snapshot_reason")
	snapshotNonce := mmdsString(client, "snapshot_nonce")
	if snapshotURL == "" || snapshotToken == "" || snapshotName == "" || snapshotNonce == "" {
		return nil
	}
	if strings.TrimSpace(readFile(lastSnapshotNonceFile)) == snapshotNonce {
		return nil
	}
	if snapshotReason == "" {
		snapshotReason = "pre-upgrade"
	}

	maxAttempts := envInt("LATTICEVE_SNAPSHOT_UPLOAD_MAX_ATTEMPTS", 3)
	attemptsFile := filepath.Join(snapshotAttemptsDir, safeStateName(snapshotNonce))
	attempts := parseInt(strings.TrimSpace(readFile(attemptsFile)))
	if attempts >= maxAttempts {
		logf("%s etcd snapshot upload attempts exhausted: name=%s nonce=%s attempts=%d", now(), snapshotName, snapshotNonce, attempts)
		cleanupSnapshotFiles(snapshotName)
		_ = os.WriteFile(lastSnapshotNonceFile, []byte(snapshotNonce), 0644)
		return nil
	}
	attempts++
	_ = os.WriteFile(attemptsFile, []byte(strconv.Itoa(attempts)), 0644)

	if err := os.MkdirAll(snapshotDir, 0755); err != nil {
		return err
	}
	logf("%s etcd snapshot requested: name=%s nonce=%s attempts=%d", now(), snapshotName, snapshotNonce, attempts)
	out, err := runCommand("/usr/local/bin/k3s", "etcd-snapshot", "save", "--name", snapshotName, "--dir", snapshotDir)
	appendLog(out)
	if err != nil {
		cleanupSnapshotFiles(snapshotName)
		logf("%s etcd snapshot create failed: name=%s nonce=%s err=%v", now(), snapshotName, snapshotNonce, err)
		return nil
	}
	snapFile := latestSnapshotFile(snapshotName)
	if snapFile == "" {
		logf("%s etcd snapshot file missing after save: name=%s", now(), snapshotName)
		return nil
	}
	if info, err := os.Stat(snapFile); err != nil || info.Size() == 0 {
		cleanupSnapshotFiles(snapshotName)
		logf("%s etcd snapshot file empty after save: name=%s file=%s", now(), snapshotName, snapFile)
		return nil
	}

	err = uploadSnapshot(snapshotURL, snapshotToken, snapshotName, snapshotReason, snapFile)
	if err != nil {
		cleanupSnapshotFiles(snapshotName)
		logf("%s etcd snapshot upload failed: file=%s attempts=%d err=%v", now(), snapFile, attempts, err)
		return nil
	}
	_ = os.WriteFile(lastSnapshotNonceFile, []byte(snapshotNonce), 0644)
	_ = os.Remove(attemptsFile)
	_ = os.Remove(snapFile)
	logf("%s etcd snapshot uploaded: file=%s attempts=%d", now(), snapFile, attempts)
	return nil
}

func uploadSnapshot(url, token, name, reason, file string) error {
	body, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	timeout := time.Duration(envInt("LATTICEVE_SNAPSHOT_UPLOAD_TIMEOUT", 20)) * time.Second
	client := &http.Client{Timeout: timeout, Transport: snapshotTransport()}
	var lastErr error
	tries := envInt("LATTICEVE_SNAPSHOT_UPLOAD_TRIES", 2)
	for i := 1; i <= tries; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			cancel()
			return err
		}
		req.Header.Set("X-Snapshot-Token", token)
		req.Header.Set("X-Snapshot-Name", name)
		req.Header.Set("X-Snapshot-Reason", reason)
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			cancel()
		} else {
			respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			cancel()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return nil
			}
			lastErr = fmt.Errorf("controller returned %s: %s", resp.Status, strings.TrimSpace(string(respBody)))
		}
		if i < tries {
			time.Sleep(2 * time.Second)
		}
	}
	return lastErr
}

func snapshotTransport() http.RoundTripper {
	// Match the historical shell behavior: use controller CA if the image has one,
	// otherwise allow the self-signed controller cert. LatticeVE authenticates the
	// upload with X-Snapshot-Token.
	if pem, err := os.ReadFile(controllerCAPath); err == nil && len(pem) > 0 {
		pool, _ := x509.SystemCertPool()
		if pool == nil {
			pool = x509.NewCertPool()
		}
		if pool.AppendCertsFromPEM(pem) {
			return &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}
		}
	}
	return &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
}

func mmdsString(client *http.Client, key string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, mmdsBase+"/"+key, nil)
	if err != nil {
		return ""
	}
	if token := fetchMMDSToken(client); token != "" {
		req.Header.Set("X-metadata-token", token)
	}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return ""
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return ""
	}
	return strings.Trim(strings.TrimSpace(string(b)), `"`)
}

func fetchMMDSToken(client *http.Client) string {
	if mmdsToken != "" && time.Now().Before(mmdsTokenExpires) {
		return mmdsToken
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, mmdsBase+"/latest/api/token", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("X-metadata-token-ttl-seconds", "21600")
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return ""
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return ""
	}
	token := strings.TrimSpace(string(b))
	if token != "" {
		mmdsToken = token
		mmdsTokenExpires = time.Now().Add(350 * time.Minute)
	}
	return token
}

func runCommand(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	return cmd.CombinedOutput()
}

func latestSnapshotFile(name string) string {
	matches, _ := filepath.Glob(filepath.Join(snapshotDir, name+"*"))
	if len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[len(matches)-1]
}

func cleanupSnapshotFiles(name string) {
	matches, _ := filepath.Glob(filepath.Join(snapshotDir, name+"*"))
	for _, f := range matches {
		_ = os.Remove(f)
	}
}

func safeStateName(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "empty"
	}
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func readFile(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

func parseInt(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func envInt(name string, def int) int {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func now() string { return time.Now().Format(time.RFC3339) }

func logf(format string, args ...any) { appendLog([]byte(fmt.Sprintf(format+"\n", args...))) }

func appendLog(p []byte) {
	logMu.Lock()
	defer logMu.Unlock()
	capLogLocked()
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		_, _ = f.Write(p)
		_ = f.Close()
	}
	capLogLocked()
}

func capLogLocked() {
	maxBytes := int64(envInt("LATTICEVE_WATCH_LOG_MAX_BYTES", 1048576))
	keepBytes := int64(envInt("LATTICEVE_WATCH_LOG_KEEP_BYTES", 262144))
	info, err := os.Stat(logPath)
	if err != nil || info.Size() <= maxBytes {
		return
	}
	f, err := os.Open(logPath)
	if err != nil {
		return
	}
	defer f.Close()
	if info.Size() > keepBytes {
		_, _ = f.Seek(-keepBytes, io.SeekEnd)
	}
	data, err := io.ReadAll(io.LimitReader(f, keepBytes))
	if err != nil {
		return
	}
	_ = os.WriteFile(logPath, data, 0644)
}
