package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	mmdsBase       = "http://169.254.169.254"
	kubeconfigPath = "/etc/rancher/k3s/k3s.yaml"
	logPath        = "/var/log/latticeve-k3s-callback.log"
	logMaxBytes    = 1 << 20
	logKeepBytes   = 256 << 10
)

func main() {
	_ = os.MkdirAll("/var/log", 0755)
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.SetOutput(os.Stderr)
	} else {
		defer f.Close()
		log.SetOutput(&cappedLogWriter{f: f, path: logPath})
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Println("latticeve-k3s-callback started")

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	role, err := waitMMDS(client, "role", 60*time.Second)
	if err != nil {
		log.Printf("role unavailable, exiting without callback: %v", err)
		return
	}
	if role != "server" {
		log.Printf("role=%q does not post kubeconfig, exiting", role)
		return
	}

	deadline := time.Now().Add(30 * time.Minute)
	attempt := 0
	for time.Now().Before(deadline) {
		attempt++
		callback, cbErr := mmds(client, "callback")
		token, tokErr := mmds(client, "callback_token")
		if cbErr != nil || tokErr != nil || callback == "" || token == "" {
			log.Printf("attempt=%d waiting for callback metadata callback=%q cb_err=%v token_present=%t token_err=%v", attempt, callback, cbErr, token != "", tokErr)
			time.Sleep(2 * time.Second)
			continue
		}

		kubeconfig, err := os.ReadFile(kubeconfigPath)
		if err != nil || len(bytes.TrimSpace(kubeconfig)) == 0 {
			log.Printf("attempt=%d waiting for kubeconfig path=%s err=%v", attempt, kubeconfigPath, err)
			time.Sleep(2 * time.Second)
			continue
		}

		if err := postKubeconfig(client, callback, token, kubeconfig); err != nil {
			log.Printf("attempt=%d post failed: %v", attempt, err)
			time.Sleep(2 * time.Second)
			continue
		}
		log.Printf("attempt=%d kubeconfig callback posted successfully", attempt)
		return
	}
	log.Printf("timed out waiting to post kubeconfig after %s", 30*time.Minute)
	os.Exit(1)
}

func waitMMDS(client *http.Client, key string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		value, err := mmds(client, key)
		if err == nil && value != "" {
			return value, nil
		}
		lastErr = err
		time.Sleep(2 * time.Second)
	}
	if lastErr != nil {
		return "", lastErr
	}
	return "", fmt.Errorf("timed out waiting for %s", key)
}

func mmds(client *http.Client, key string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, mmdsBase+"/"+key, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("mmds %s returned %s", key, resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	return strings.Trim(strings.TrimSpace(string(b)), `"`), nil
}

func postKubeconfig(client *http.Client, callback, token string, kubeconfig []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, callback, bytes.NewReader(kubeconfig))
	if err != nil {
		return err
	}
	req.Header.Set("X-Cluster-Token", token)
	req.Header.Set("Content-Type", "application/yaml")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("controller returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

type cappedLogWriter struct {
	f    *os.File
	path string
}

func (w *cappedLogWriter) Write(p []byte) (int, error) {
	capLogFile(w.path)
	return w.f.Write(p)
}

func capLogFile(path string) {
	info, err := os.Stat(path)
	if err != nil || info.Size() <= logMaxBytes {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.Seek(-logKeepBytes, io.SeekEnd); err != nil {
		_, _ = f.Seek(0, io.SeekStart)
	}
	data, err := io.ReadAll(io.LimitReader(f, logKeepBytes))
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0644)
}
