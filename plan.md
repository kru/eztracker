## EZTRACKER Plan


### Overview

Lightweight WakaTime to track Neovim/Sublime coding activity (projects, languages, time). 
Weekly email summaries.

### Components

Client: (Lua extentions for neovim, Sublime package) -> send data to CLI (activity, sends heartbeats)

Server: Go REST API, stores data, sends weekly emails.

Database: SQLite for time-tracking data.
Email Service: SMTP for weekly summaries (e.g., SendGrid).

### Client Design

Platform: Cross-Platform.

Functionality:
- [] Tracks file events (BufEnter, BufWrite, VimLeave).
- Infers project (parent directory), language (file extension/filetype).
- Sends JSON heartbeats via HTTP POST (batched ~5m) via CLI program.


Config (.env):API_ENDPOINT=http://server:8080/heartbeats
HEARTBEAT_INTERVAL=5m
USER_ID=unique_user_id
API_KEY=secret_key


### Server Design

Hosting: DigitalOcean, Go REST API.
Functionality:
Receives heartbeats (/heartbeats).
Stores in SQLite.
Emails weekly summaries (projects, languages, time).


Implementation:
Go standard HTTP server
SQLite database.
Cron job for emails.


Config (.env):DATABASE_PATH=/path/to/db.sqlite
EMAIL_PROVIDER=smtp://user:pass@smtp.sendgrid.net:587
SERVER_PORT=8080
SUMMARY_SCHEDULE=0 0 * * 0



### Database Schema

#### Users
```
id: integer
email: string
name: string
timestamp: Date
```

#### Projects
```
id: integer
user_id: integer
name: string (check git file or get root project)
```

#### Heartbeats
```
id: integer
user_id: integer
language: string
file_path: string
duration: float (in seconds)
timestamp: Date
os: string
editor: string
```

### Data Flow

Lua plugin detects Neovim events.
Logs time, project, language.
Sends JSON heartbeat to server.
Server stores in SQLite.
Weekly cron job aggregates data, sends email.

### Tech Stack

Client: command line
Server: Go (Gin/std), SQLite, go-cron.
Email: SMTP (SendGrid/AWS SES).
Config: godotenv (server), Lua .env parser (client).
Deployment: Docker (server).


### Scalability

SQLite for single-user.
Batch heartbeats to reduce network load.

### Development Plan

Neovim/Sublime package that will accumulate data
Pipe the data to CLI program asynchronously
CLI will send the data to server
Add cron job for email summaries.


### Current Progress

- [x] There are data in Wakatime since 2017 exported
- [x] Review the Data and pick what are needed
- [x] Create Postgres Schemas based on data and additional tables if required
- [ ] Create a simple program to insert data from JSON to SQLite table
- [ ] Research how Wakatime trigger their CLI in non abusive way, because when we tried to trigger curl via lua, it causes annoying behaviour on the editor
- [ ] Based on the research result, decide what is the threshold of duration of creating a heartbeat for CLI

