package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	_ "modernc.org/sqlite"
)

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func seedTestDB(t *testing.T, db *sql.DB) {
	t.Helper()
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}
}

// ── initSchema tests ─────────────────────────────────────────────────────────

func TestInitSchema(t *testing.T) {
	db := openTestDB(t)
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema: %v", err)
	}

	// Verify the memories table exists.
	var tableName string
	err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name='memories'`).Scan(&tableName)
	if err != nil {
		t.Fatalf("memories table not found: %v", err)
	}

	// Verify the FTS5 virtual table exists.
	err = db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name='memories_fts'`).Scan(&tableName)
	if err != nil {
		t.Fatalf("memories_fts virtual table not found: %v", err)
	}

	// Verify idempotency — calling again should not fail.
	if err := initSchema(db); err != nil {
		t.Fatalf("initSchema (idempotent): %v", err)
	}
}

// ── Core database function tests ─────────────────────────────────────────────

func TestStoreMemory(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	id, storedAt, err := storeMemory(db, "Kafka consumer lag detected", []string{"kafka", "payments"})
	if err != nil {
		t.Fatalf("storeMemory: %v", err)
	}
	if id <= 0 {
		t.Errorf("expected positive id, got %d", id)
	}
	if storedAt == "" {
		t.Error("expected non-empty stored_at")
	}
}

func TestSearchMemories(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "Kafka consumer lag detected in payments namespace", []string{"kafka"})
	storeMemory(db, "OOM crash in checkout service", []string{"oom"})
	storeMemory(db, "Deployment rollback completed for auth service", nil)

	results, err := searchMemories(db, "kafka consumer", 5)
	if err != nil {
		t.Fatalf("searchMemories: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("expected at least 1 search result")
	}
	if results[0].Content != "Kafka consumer lag detected in payments namespace" {
		t.Errorf("first result content = %q", results[0].Content)
	}
}

func TestSearchMemories_Fallback(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "the payments service had an OOM kill event", nil)

	results, err := searchMemories(db, "OOM kill", 5)
	if err != nil {
		t.Fatalf("searchMemories fallback: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("expected LIKE fallback to find the entry")
	}
}

func TestListMemories(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "first entry", nil)
	storeMemory(db, "second entry", nil)
	storeMemory(db, "third entry", nil)

	results, err := listMemories(db, "", 20)
	if err != nil {
		t.Fatalf("listMemories: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(results))
	}

	contents := map[string]bool{}
	for _, e := range results {
		contents[e.Content] = true
	}
	for _, want := range []string{"first entry", "second entry", "third entry"} {
		if !contents[want] {
			t.Errorf("missing entry %q in list results", want)
		}
	}
}

func TestListMemories_WithTags(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "kafka issue", []string{"kafka", "infra"})
	storeMemory(db, "redis issue", []string{"redis", "infra"})
	storeMemory(db, "code review notes", []string{"review"})

	results, err := listMemories(db, "kafka", 20)
	if err != nil {
		t.Fatalf("listMemories with tags: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 entry with kafka tag, got %d", len(results))
	}
	if results[0].Content != "kafka issue" {
		t.Errorf("entry content = %q", results[0].Content)
	}
}

// ── fts5Query tests ──────────────────────────────────────────────────────────

func TestFts5Query(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"kafka consumer", "kafka* AND consumer*"},
		{"single", "single*"},
		{"", ""},
		{`special "chars" and (parens)`, "special* AND chars* AND and* AND parens*"},
		{"***", "***"}, // all chars stripped → empty terms → returns original
	}

	for _, tt := range tests {
		got := fts5Query(tt.input)
		if got != tt.want {
			t.Errorf("fts5Query(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

// ── HTTP handler tests ───────────────────────────────────────────────────────

func TestHealthHandler(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/health", nil)

	handler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}
	handler(w, r)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
	if w.Body.String() != "ok" {
		t.Errorf("body = %q, want ok", w.Body.String())
	}
}

func TestStoreHandler(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	body := `{"content":"Kafka lag in payments","tags":["kafka","payments"]}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/store", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")

	storeHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse response: %v", err)
	}
	if !resp.Success {
		t.Fatalf("expected success, got error: %s", resp.Error)
	}

	// Content should contain an id and stored_at.
	contentBytes, _ := json.Marshal(resp.Content)
	var stored map[string]any
	if err := json.Unmarshal(contentBytes, &stored); err != nil {
		t.Fatalf("parse content: %v", err)
	}
	if id, ok := stored["id"].(float64); !ok || id <= 0 {
		t.Errorf("expected positive id, got %v", stored["id"])
	}
}

func TestStoreHandler_MissingContent(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	body := `{}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/store", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")

	storeHandler(db)(w, r)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestStoreHandler_InvalidJSON(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/store", bytes.NewBufferString("not json"))
	r.Header.Set("Content-Type", "application/json")

	storeHandler(db)(w, r)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestSearchHandler(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "Kafka consumer lag detected in payments namespace", []string{"kafka"})
	storeMemory(db, "OOM crash in checkout service", []string{"oom"})

	body := `{"query":"kafka consumer","top_k":5}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/search", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")

	searchHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse response: %v", err)
	}
	if !resp.Success {
		t.Fatalf("expected success, got error: %s", resp.Error)
	}

	contentBytes, _ := json.Marshal(resp.Content)
	var entries []memoryEntry
	if err := json.Unmarshal(contentBytes, &entries); err != nil {
		t.Fatalf("parse content: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("expected at least 1 search result")
	}
	if entries[0].Content != "Kafka consumer lag detected in payments namespace" {
		t.Errorf("first result content = %q", entries[0].Content)
	}
}

func TestSearchHandler_MissingQuery(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	body := `{}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/search", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")

	searchHandler(db)(w, r)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestSearchHandler_DefaultTopK(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "entry one", nil)

	body := `{"query":"entry"}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/search", bytes.NewBufferString(body))
	r.Header.Set("Content-Type", "application/json")

	searchHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !resp.Success {
		t.Fatalf("expected success, got error: %s", resp.Error)
	}
}

func TestListHandler(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "first entry", nil)
	storeMemory(db, "second entry", nil)

	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/list", nil)

	listHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("parse response: %v", err)
	}
	if !resp.Success {
		t.Fatalf("expected success, got error: %s", resp.Error)
	}

	contentBytes, _ := json.Marshal(resp.Content)
	var entries []memoryEntry
	if err := json.Unmarshal(contentBytes, &entries); err != nil {
		t.Fatalf("parse content: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
}

func TestListHandler_WithTags(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "kafka issue", []string{"kafka", "infra"})
	storeMemory(db, "redis issue", []string{"redis", "infra"})

	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/list?tags=kafka", nil)

	listHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	contentBytes, _ := json.Marshal(resp.Content)
	var entries []memoryEntry
	json.Unmarshal(contentBytes, &entries)

	if len(entries) != 1 {
		t.Fatalf("expected 1 entry with kafka tag, got %d", len(entries))
	}
	if entries[0].Content != "kafka issue" {
		t.Errorf("entry content = %q", entries[0].Content)
	}
}

func TestListHandler_WithLimit(t *testing.T) {
	db := openTestDB(t)
	seedTestDB(t, db)

	storeMemory(db, "entry 1", nil)
	storeMemory(db, "entry 2", nil)
	storeMemory(db, "entry 3", nil)

	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/list?limit=2", nil)

	listHandler(db)(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp apiResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	contentBytes, _ := json.Marshal(resp.Content)
	var entries []memoryEntry
	json.Unmarshal(contentBytes, &entries)

	if len(entries) != 2 {
		t.Fatalf("expected 2 entries (limit=2), got %d", len(entries))
	}
}
