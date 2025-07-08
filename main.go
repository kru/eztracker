package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/smtp"
	"os"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Config struct {
	DBPath     string
	SMTPHost   string
	SMTPPort   string
	SMTPUser   string
	SMTPPass   string
	ServerPort string
	ApiKey     string
}

type Heartbeat struct {
	UserID    string  `json:"user_id"`
	Project   string  `json:"project"`
	Language  string  `json:"language"`
	FilePath  string  `json:"file_path"`
	Duration  float64 `json:"duration"`
	Timestamp int64   `json:"timestamp"`
}

// Load .env manually
func loadEnv() (Config, error) {
	data, err := os.ReadFile(".env")
	if err != nil {
		return Config{}, err
	}

	config := Config{}
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key, value := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		switch key {
		case "DATABASE_PATH":
			fmt.Printf("DB %s\n", value)
			config.DBPath = value
		case "EMAIL_PROVIDER":
			config.SMTPHost = strings.Split(value, "@")[1]
			config.SMTPPort = strings.Split(strings.Split(value, ":")[2], "/")[0]
			config.SMTPUser = strings.Split(strings.Split(value, "//")[1], ":")[0]
			config.SMTPPass = strings.Split(
				strings.Split(strings.Split(value, "//")[1], ":")[1], "@")[0]
		case "SERVER_PORT":
			config.ServerPort = value
		case "API_KEY":
			fmt.Printf("API KEY: %s\n", value)
			config.ApiKey = value
		}
	}
	return config, nil
}

func main() {
	// Load .env manually
	config, err := loadEnv()
	if err != nil {
		log.Fatal("Error loading .env: ", err)
	}

	// Initialize SQLite
	db, err := sql.Open("sqlite3", config.DBPath)
	if err != nil {
		log.Fatal("DB error: ", err)
	}
	defer db.Close()

	// Create tables
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT);
		CREATE TABLE IF NOT EXISTS projects (
			id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, name TEXT, path TEXT);
		CREATE TABLE IF NOT EXISTS heartbeats (
			id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, project_id INTEGER, 
			language TEXT, file_path TEXT, duration REAL, timestamp INTEGER);
	`)
	if err != nil {
		log.Fatal("Table creation error: ", err)
	}

	// HTTP handler for heartbeats
	http.HandleFunc("/heartbeat", func(w http.ResponseWriter, r *http.Request) {

		log.Printf("Incoming request: %+v\n", r.Header)
		if r.Method != "POST" {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var hb Heartbeat
		if err := json.NewDecoder(r.Body).Decode(&hb); err != nil {
			log.Printf("decoder error: %+v\n", err)
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}

		// Verify API key
		if r.Header.Get("Authorization") != "Bearer "+config.ApiKey {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		// Get or create project
		var projectID int
		err = db.QueryRow("SELECT id FROM projects WHERE user_id = ? AND name = ?",
			hb.UserID, hb.Project).Scan(&projectID)
		if err == sql.ErrNoRows {
			res, err := db.Exec(
				"INSERT INTO projects (user_id, name, path) VALUES (?, ?, ?)",
				hb.UserID, hb.Project, hb.FilePath)
			if err != nil {
				http.Error(w, "DB error", http.StatusInternalServerError)
				return
			}
			id, _ := res.LastInsertId()
			projectID = int(id)
		} else if err != nil {
			http.Error(w, "DB error", http.StatusInternalServerError)
			return
		}

		// Insert heartbeat
		query := "INSERT INTO heartbeats (user_id, project_id, language, "
		query += "file_path, duration, timestamp) VALUES (?, ?, ?, ?, ?, ?)"

		_, err = db.Exec(query, hb.UserID, projectID, 
			hb.Language, hb.FilePath, hb.Duration, hb.Timestamp)

		if err != nil {
			http.Error(w, "DB error", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "Heartbeat received")
	})

	// Weekly email summary (runs every Sunday at midnight)
	go func() {
		for {
			now := time.Now()
			// Calculate time until next Sunday midnight
			daysUntilSunday := (7 - int(now.Weekday())) % 7
			if daysUntilSunday == 0 && now.Hour() >= 0 {
				daysUntilSunday = 7
			}
			nextRun := now.Truncate(24*time.Hour).
				AddDate(0, 0, daysUntilSunday).
				Add(24 * time.Hour)

			time.Sleep(time.Until(nextRun))

			// Send weekly summaries
			rows, err := db.Query(`
				SELECT u.email, h.user_id, p.name, h.language, 
				SUM(h.duration) as total_duration
				FROM heartbeats h
				JOIN users u ON h.user_id = u.id
				JOIN projects p ON h.project_id = p.id
				WHERE h.timestamp >= ? AND h.timestamp < ?
				GROUP BY h.user_id, p.name, h.language
			`, now.AddDate(0, 0, -7).Unix(), now.Unix())
			if err != nil {
				log.Println("Summary query error: ", err)
				continue
			}

			summaries := make(map[string][]string)
			for rows.Next() {
				var email, userID, project, language string
				var totalDuration float64
				if err := rows.Scan(&email, &userID,
					&project, &language, &totalDuration); err != nil {
					log.Println("Row scan error: ", err)
					continue
				}
				summaries[userID] = append(summaries[userID], fmt.Sprintf(
					"Project: %s, Language: %s, Time: %.2f hours",
					project, language, totalDuration/3600))
			}
			rows.Close()

			for userID, lines := range summaries {
				var email string
				db.QueryRow("SELECT email FROM users WHERE id = ?", userID).Scan(&email)
				if email == "" {
					continue
				}
				
				str := "From: %s\r\nTo: %s\r\nSubject: "
				str += "Eztracker Weekly Summary\r\n\r\nYour coding activity:\n%s\n"

				msg := fmt.Sprintf(str, config.SMTPUser, email, strings.Join(lines, "\n"))
				err := smtp.SendMail(config.SMTPHost+":"+config.SMTPPort,
					smtp.PlainAuth("", config.SMTPUser, config.SMTPPass, config.SMTPHost),
					config.SMTPUser, []string{email}, []byte(msg))
				if err != nil {
					log.Println("Email error: ", err)
				}
			}
		}
	}()

	// Start server
	log.Printf("Server running on :%s", config.ServerPort)
	log.Fatal(http.ListenAndServe(":"+config.ServerPort, nil))
}
