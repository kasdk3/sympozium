// memory-server runs as a standalone Deployment per SympoziumInstance.
// It provides persistent memory for Sympozium agents via an HTTP API,
// backed by SQLite with FTS5 for full-text search.
//
// The SQLite database lives on a PersistentVolume so data survives across
// ephemeral agent pod runs. Agent pods call this server over HTTP via a
// ClusterIP Service.
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const defaultDBPath = "/data/memory.db"

// apiResponse is the standard JSON response format.
type apiResponse struct {
	Success bool   `json:"success"`
	Content any    `json:"content,omitempty"`
	Error   string `json:"error,omitempty"`
}

// memoryEntry represents a stored memory.
type memoryEntry struct {
	ID        int64    `json:"id"`
	Content   string   `json:"content"`
	Tags      []string `json:"tags,omitempty"`
	CreatedAt string   `json:"created_at"`
	UpdatedAt string   `json:"updated_at"`
}

func main() {
	dbPath := envOr("MEMORY_DB_PATH", defaultDBPath)
	port := envOr("MEMORY_PORT", "8080")

	// Ensure database directory exists.
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		log.Fatalf("failed to create db directory: %v", err)
	}

	// Open SQLite database and initialize schema.
	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(wal)&_pragma=busy_timeout(5000)")
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}
	defer db.Close()

	if err := initSchema(db); err != nil {
		log.Fatalf("failed to initialize schema: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /search", searchHandler(db))
	mux.HandleFunc("POST /store", storeHandler(db))
	mux.HandleFunc("GET /list", listHandler(db))
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	addr := ":" + port
	log.Printf("[memory-server] listening on %s, db=%s", addr, dbPath)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func searchHandler(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query string `json:"query"`
			TopK  int    `json:"top_k"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			log.Printf("[search] bad request: %v", err)
			writeJSON(w, http.StatusBadRequest, apiResponse{Error: "invalid JSON body"})
			return
		}
		if req.Query == "" {
			log.Printf("[search] rejected: empty query")
			writeJSON(w, http.StatusBadRequest, apiResponse{Error: "'query' is required"})
			return
		}
		if req.TopK <= 0 {
			req.TopK = 5
		}

		log.Printf("[search] query=%q top_k=%d", truncateLog(req.Query, 120), req.TopK)
		results, err := searchMemories(db, req.Query, req.TopK)
		if err != nil {
			log.Printf("[search] error: %v", err)
			writeJSON(w, http.StatusInternalServerError, apiResponse{Error: err.Error()})
			return
		}
		log.Printf("[search] returned %d result(s)", len(results))
		writeJSON(w, http.StatusOK, apiResponse{Success: true, Content: results})
	}
}

func storeHandler(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Content string   `json:"content"`
			Tags    []string `json:"tags"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			log.Printf("[store] bad request: %v", err)
			writeJSON(w, http.StatusBadRequest, apiResponse{Error: "invalid JSON body"})
			return
		}
		if req.Content == "" {
			log.Printf("[store] rejected: empty content")
			writeJSON(w, http.StatusBadRequest, apiResponse{Error: "'content' is required"})
			return
		}

		log.Printf("[store] content=%d bytes tags=%v", len(req.Content), req.Tags)
		id, storedAt, err := storeMemory(db, req.Content, req.Tags)
		if err != nil {
			log.Printf("[store] error: %v", err)
			writeJSON(w, http.StatusInternalServerError, apiResponse{Error: err.Error()})
			return
		}
		log.Printf("[store] saved id=%d at=%s", id, storedAt)
		writeJSON(w, http.StatusOK, apiResponse{
			Success: true,
			Content: map[string]any{"id": id, "stored_at": storedAt},
		})
	}
}

func listHandler(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tags := r.URL.Query().Get("tags")
		limit := 20
		if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
			limit = l
		}

		log.Printf("[list] tags=%q limit=%d", tags, limit)
		results, err := listMemories(db, tags, limit)
		if err != nil {
			log.Printf("[list] error: %v", err)
			writeJSON(w, http.StatusInternalServerError, apiResponse{Error: err.Error()})
			return
		}
		log.Printf("[list] returned %d entry/entries", len(results))
		writeJSON(w, http.StatusOK, apiResponse{Success: true, Content: results})
	}
}

// --- Core database operations ---

func searchMemories(db *sql.DB, query string, topK int) ([]memoryEntry, error) {
	// FTS5 search with ranking.
	rows, err := db.Query(`
		SELECT m.id, m.content, m.tags, m.created_at, m.updated_at
		FROM memories_fts fts
		JOIN memories m ON m.id = fts.rowid
		WHERE memories_fts MATCH ?
		ORDER BY rank
		LIMIT ?
	`, fts5Query(query), topK)
	if err != nil {
		// If FTS query fails (bad syntax), fall back to LIKE search.
		rows, err = db.Query(`
			SELECT id, content, tags, created_at, updated_at
			FROM memories
			WHERE content LIKE ?
			ORDER BY updated_at DESC
			LIMIT ?
		`, "%"+query+"%", topK)
		if err != nil {
			return nil, fmt.Errorf("search failed: %w", err)
		}
	}
	defer rows.Close()
	return scanEntries(rows)
}

func storeMemory(db *sql.DB, content string, tags []string) (int64, string, error) {
	tagsStr := strings.Join(tags, ",")
	now := time.Now().UTC().Format(time.RFC3339)
	result, err := db.Exec(`
		INSERT INTO memories (content, tags, created_at, updated_at)
		VALUES (?, ?, ?, ?)
	`, content, tagsStr, now, now)
	if err != nil {
		return 0, "", fmt.Errorf("store failed: %w", err)
	}
	id, _ := result.LastInsertId()
	return id, now, nil
}

func listMemories(db *sql.DB, tags string, limit int) ([]memoryEntry, error) {
	var rows *sql.Rows
	var err error
	if tags != "" {
		rows, err = db.Query(`
			SELECT id, content, tags, created_at, updated_at
			FROM memories
			WHERE tags LIKE ?
			ORDER BY updated_at DESC
			LIMIT ?
		`, "%"+tags+"%", limit)
	} else {
		rows, err = db.Query(`
			SELECT id, content, tags, created_at, updated_at
			FROM memories
			ORDER BY updated_at DESC
			LIMIT ?
		`, limit)
	}
	if err != nil {
		return nil, fmt.Errorf("list failed: %w", err)
	}
	defer rows.Close()
	return scanEntries(rows)
}

func scanEntries(rows *sql.Rows) ([]memoryEntry, error) {
	var results []memoryEntry
	for rows.Next() {
		var e memoryEntry
		var tags string
		if err := rows.Scan(&e.ID, &e.Content, &tags, &e.CreatedAt, &e.UpdatedAt); err != nil {
			continue
		}
		if tags != "" {
			e.Tags = strings.Split(tags, ",")
		}
		results = append(results, e)
	}
	if results == nil {
		results = []memoryEntry{}
	}
	return results, nil
}

// initSchema creates the memories table and FTS5 virtual table.
func initSchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS memories (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			content    TEXT NOT NULL,
			tags       TEXT DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		);

		CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
			content,
			content=memories,
			content_rowid=id,
			tokenize='porter unicode61'
		);

		-- Triggers to keep FTS index in sync.
		CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
			INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
		END;

		CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
			INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.id, old.content);
		END;

		CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
			INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.id, old.content);
			INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
		END;

		CREATE INDEX IF NOT EXISTS idx_memories_updated ON memories(updated_at DESC);
		CREATE INDEX IF NOT EXISTS idx_memories_tags ON memories(tags);
	`)
	return err
}

// fts5Query converts a natural language query into an FTS5 query.
// Each word becomes a prefix search term joined with AND.
func fts5Query(query string) string {
	words := strings.Fields(query)
	if len(words) == 0 {
		return query
	}
	terms := make([]string, 0, len(words))
	for _, w := range words {
		// Strip special FTS5 characters to prevent syntax errors.
		w = strings.Map(func(r rune) rune {
			if r == '"' || r == '*' || r == '+' || r == '-' || r == '(' || r == ')' || r == ':' || r == '^' {
				return -1
			}
			return r
		}, w)
		if w != "" {
			terms = append(terms, w+"*")
		}
	}
	if len(terms) == 0 {
		return query
	}
	return strings.Join(terms, " AND ")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func truncateLog(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
