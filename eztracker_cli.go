package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	ExitCodeSuccess          = 0
	ExitCodeConfigParseError = 103
	ExitCodeAPIKeyError      = 104
)

type Config struct {
	APIKey    string
	ServerURL string
	Debug     bool
}

type Heartbeat struct {
	Entity            string  `json:"entity"`
	Timestamp         float64 `json:"timestamp"`
	Language          string  `json:"language,omitempty"`
	AlternateLanguage string  `json:"alternate_language,omitempty"`
	IsWrite           bool    `json:"is_write"`
	Plugin            string  `json:"plugin"`
	Duration          float64 `json:"duration"`
}

type ServerHeartbeat struct {
	UserID    string  `json:"user_id"`
	Project   string  `json:"project"`
	Language  string  `json:"language"`
	FilePath  string  `json:"file_path"`
	Duration  float64 `json:"duration"`
	Timestamp int64   `json:"timestamp"`
}

func loadConfig() (Config, error) {
	config := Config{
		ServerURL: "http://localhost:8080", // Default server URL
	}

	// Check environment variables first
	if apiKey := os.Getenv("API_KEY"); apiKey != "" {
		config.APIKey = apiKey
	}
	if serverURL := os.Getenv("EZTRACKER_SERVER_URL"); serverURL != "" {
		config.ServerURL = serverURL
	}
	if debug := os.Getenv("EZTRACKER_DEBUG"); debug == "true" {
		config.Debug = true
	}

	// Override with config file if it exists
	home, err := os.UserHomeDir()
	if err != nil {
		return config, fmt.Errorf("failed to get home directory: %v", err)
	}
	configPath := filepath.Join(home, ".eztracker.cfg")
	data, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return config, fmt.Errorf("failed to read config file: %v", err)
	}

	if len(data) > 0 {
		lines := strings.Split(string(data), "\n")
		var currentSection string
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
				continue
			}
			if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
				currentSection = strings.Trim(line, "[]")
				continue
			}
			if currentSection == "settings" {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key := strings.TrimSpace(parts[0])
				value := strings.TrimSpace(parts[1])
				switch key {
				case "api_key":
					config.APIKey = value
				case "server_url":
					config.ServerURL = value
				case "debug":
					config.Debug = value == "true"
				}
			}
		}
	}

	if config.APIKey == "" {
		return config, fmt.Errorf("API key not found")
	}

	return config, nil
}

func main() {
	// Define flags
	entity := flag.String("entity", "", "File path for the heartbeat")
	timeStr := flag.String("time", "", "Timestamp for the heartbeat (seconds.micros)")
	language := flag.String("language", "", "Language of the file")
	alternateLanguage := flag.String("alternate-language", "", "Alternate language")
	isWrite := flag.Bool("write", false, "Whether this is a write event")
	plugin := flag.String("plugin", "eztracker-cli", "Plugin identifier")
	extraHeartbeats := flag.String("extra-heartbeats", "", "JSON array of additional heartbeats")
	today := flag.Bool("today", false, "Fetch today's summary")
	version := flag.Bool("version", false, "Show CLI version")
	duration := flag.Float64("duration", 0.0, "Duration if same file edited")
	flag.Parse()

	config, err := loadConfig()
	if err != nil {
		if strings.Contains(err.Error(), "API key not found") {
			fmt.Fprintln(os.Stderr, "Error: API key not found in config or environment")
			os.Exit(ExitCodeAPIKeyError)
		}
		fmt.Fprintf(os.Stderr, "Error loading config: %v\n", err)
		os.Exit(ExitCodeConfigParseError)
	}

	if config.Debug {
		fmt.Printf("Debug: Config loaded: APIKey=%s, ServerURL=%s, Debug=%v\n",
			config.APIKey, config.ServerURL, config.Debug)
	}

	if *version {
		fmt.Println("eztracker-cli v0.0.1")
		os.Exit(ExitCodeSuccess)
	}

	if *today {
		// Placeholder for fetching today's summary (requires server endpoint)
		fmt.Println("Today's summary not implemented")
		os.Exit(ExitCodeSuccess)
	}

	if *entity == "" || *timeStr == "" {
		fmt.Fprintln(os.Stderr, "Error: --entity and --time are required")
		os.Exit(1)
	}

	// Parse timestamp
	timestamp, err := strconv.ParseFloat(*timeStr, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: Invalid timestamp format: %v\n", err)
		os.Exit(1)
	}

	// Create primary heartbeat
	heartbeat := Heartbeat{
		Entity:            *entity,
		Timestamp:         timestamp,
		Language:          *language,
		AlternateLanguage: *alternateLanguage,
		IsWrite:           *isWrite,
		Plugin:            *plugin,
		Duration:          *duration,
	}

	heartbeats := []Heartbeat{heartbeat}

	// Process extra heartbeats from JSON input
	if *extraHeartbeats != "" {
		var extra []Heartbeat
		if err := json.Unmarshal([]byte(*extraHeartbeats), &extra); err != nil {
			fmt.Fprintf(os.Stderr, "Error: Invalid extra heartbeats JSON: %v\n", err)
			os.Exit(1)
		}

		if config.Debug {
			fmt.Printf("heartbeat payload: %+v", extra)
		}

		heartbeats = append(heartbeats, extra...)
	}

	// Send heartbeats
	for _, hb := range heartbeats {
		if err := sendHeartbeat(config, hb); err != nil {
			fmt.Fprintf(os.Stderr, "Error sending heartbeat: %v\n", err)
			os.Exit(1)
		}
	}

	if config.Debug {
		fmt.Println("Debug: Heartbeats sent successfully")
	}
}

func sendHeartbeat(config Config, hb Heartbeat) error {
	if hb.Duration == 0 {
		fmt.Printf("duration is 0, not sending it: %+v", hb)
		return nil
	}
	// Extract project name from file path (simplified, assumes last dir is project)
	project := "unknown"
	if parts := strings.Split(hb.Entity, string(os.PathSeparator)); len(parts) > 1 {
		project = parts[len(parts)-2]
	}

	// Convert to server heartbeat format
	serverHB := ServerHeartbeat{
		UserID:    "krisrp", // Hardcoded for simplicity; should be configurable
		Project:   project,
		Language:  hb.Language,
		FilePath:  hb.Entity,
		Duration:  hb.Duration,
		Timestamp: int64(hb.Timestamp),
	}

	if hb.AlternateLanguage != "" && hb.Language == "" {
		serverHB.Language = hb.AlternateLanguage
	}

	data, err := json.Marshal(serverHB)
	if err != nil {
		return fmt.Errorf("failed to marshal heartbeat: %v", err)
	}

	if config.Debug {
		fmt.Printf("Debug: Sending heartbeat: %s\n", string(data))
	}

	req, err := http.NewRequest("POST", config.ServerURL+"/heartbeat", bytes.NewBuffer(data))
	if err != nil {
		return fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Authorization", "Bearer "+config.APIKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", hb.Plugin)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("server returned %d: %s", resp.StatusCode, string(body))
	}

	return nil
}
