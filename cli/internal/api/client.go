package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/aurlaw/harbinger/cli/internal/export"
)

// DefaultBaseURL is the production Worker.
const DefaultBaseURL = "https://harbinger-api.aurlaw.dev"

const (
	requestTimeout   = 30 * time.Second
	maxResponseBytes = 16 << 20
	userAgent        = "harbinger-cli"

	// Retry policy. Every W2 write is idempotent, so retrying writes is safe.
	rateLimitAttempts     = 3               // total attempts on 503 tmdb_rate_limited
	defaultRetryAfter     = 2 * time.Second // when Retry-After is absent
	transientRetries      = 2               // retries on network error / 5xx
	transientBackoffUnits = time.Second     // 1 s, then 2 s
)

// APIError is a non-2xx Worker response, decoded from the error envelope.
type APIError struct {
	Status  int
	Code    string
	Message string

	retryAfter time.Duration // from Retry-After, used for tmdb_rate_limited
}

func (e *APIError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("worker returned %d: %s", e.Status, e.Message)
	}
	return fmt.Sprintf("worker returned %d %s: %s", e.Status, e.Code, e.Message)
}

// IsAPIError reports whether err is an *APIError with the given status and
// (if non-empty) code.
func IsAPIError(err error, status int, code string) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Status == status && (code == "" || apiErr.Code == code)
}

// Client is the HTTP Worker implementation.
type Client struct {
	base *url.URL
	key  string
	http *http.Client
	// sleep waits between retries; tests replace it.
	sleep func(ctx context.Context, d time.Duration) error
}

var _ Worker = (*Client)(nil)

// NewClient returns a client for the Worker at baseURL authenticating with key.
func NewClient(baseURL, key string) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, fmt.Errorf("invalid Worker URL %q", baseURL)
	}
	return &Client{base: u, key: key, http: &http.Client{}, sleep: sleepCtx}, nil
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (c *Client) ListFilms(ctx context.Context) ([]LibraryFilm, error) {
	var out struct {
		Films []LibraryFilm `json:"films"`
	}
	err := c.do(ctx, http.MethodGet, c.endpoint("library", "films"), nil, &out)
	return out.Films, err
}

func (c *Client) UpsertFilms(ctx context.Context, films []export.Film) (UpsertResult, error) {
	var out UpsertResult
	err := c.do(ctx, http.MethodPost, c.endpoint("library", "films"), map[string]any{"films": films}, &out)
	return out, err
}

func (c *Client) RecordMatches(ctx context.Context, matches []Match) (int, error) {
	var out struct {
		Updated int `json:"updated"`
	}
	err := c.do(ctx, http.MethodPost, c.endpoint("library", "films", "matches"), map[string]any{"matches": matches}, &out)
	return out.Updated, err
}

func (c *Client) Import(ctx context.Context, req ImportRequest) (ImportResult, error) {
	var out ImportResult
	err := c.do(ctx, http.MethodPost, c.endpoint("library", "import"), req, &out)
	return out, err
}

func (c *Client) SetOverride(ctx context.Context, uri string, override *string) (LibraryFilm, error) {
	var out LibraryFilm
	body := map[string]any{"letterboxd_uri": uri, "genre_override": override}
	err := c.do(ctx, http.MethodPut, c.endpoint("library", "films", "override"), body, &out)
	return out, err
}

func (c *Client) LatestImport(ctx context.Context) (*ImportRow, error) {
	var out ImportRow
	err := c.do(ctx, http.MethodGet, c.endpoint("library", "imports", "latest"), nil, &out)
	if IsAPIError(err, http.StatusNotFound, "no_imports") {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) SearchTMDB(ctx context.Context, q SearchQuery) (SearchPage, error) {
	u := c.endpoint("tmdb", "search")
	params := url.Values{"query": {q.Query}}
	for name, v := range map[string]int{"primary_release_year": q.PrimaryReleaseYear, "year": q.Year, "page": q.Page} {
		if v != 0 {
			params.Set(name, strconv.Itoa(v))
		}
	}
	u.RawQuery = params.Encode()
	var out SearchPage
	err := c.do(ctx, http.MethodGet, u, nil, &out)
	return out, err
}

// MovieTMDB returns the /tmdb/movie/{id} body exactly as the Worker sent it.
func (c *Client) MovieTMDB(ctx context.Context, id int) (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, c.endpoint("tmdb", "movie", strconv.Itoa(id)), nil, &out)
	return out, err
}

// endpoint joins fixed path segments onto the base URL.
func (c *Client) endpoint(segments ...string) *url.URL {
	return c.base.JoinPath(segments...)
}

// do sends the request, retrying per the retry policy, and decodes a 2xx body
// into out (a *json.RawMessage receives the bytes verbatim).
func (c *Client) do(ctx context.Context, method string, u *url.URL, body any, out any) error {
	var payload []byte
	if body != nil {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		// Keep tmdb_json byte-for-byte: no HTML escaping of & < > (json.Marshal would rewrite them).
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			return fmt.Errorf("encode %s %s: %w", method, u.Path, err)
		}
		payload = buf.Bytes()
	}

	for attempt := 1; ; attempt++ {
		data, err := c.send(ctx, method, u, payload)
		if err == nil {
			if raw, ok := out.(*json.RawMessage); ok {
				*raw = data
				return nil
			}
			if err := json.Unmarshal(data, out); err != nil {
				return fmt.Errorf("%s %s: decode response: %w", method, u.Path, err)
			}
			return nil
		}

		wait, retry := retryDelay(attempt, err)
		if !retry || ctx.Err() != nil {
			return err
		}
		if err := c.sleep(ctx, wait); err != nil {
			return err
		}
	}
}

// retryDelay decides whether attempt (1-based) should be retried and after how long.
func retryDelay(attempt int, err error) (time.Duration, bool) {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		// Network error or timeout.
		return time.Duration(attempt) * transientBackoffUnits, attempt <= transientRetries
	}
	switch {
	case apiErr.Status == http.StatusServiceUnavailable && apiErr.Code == "tmdb_rate_limited":
		return apiErr.retryAfter, attempt < rateLimitAttempts
	case apiErr.Status >= 500:
		return time.Duration(attempt) * transientBackoffUnits, attempt <= transientRetries
	default:
		return 0, false // 4xx: never retried
	}
}

// send performs one attempt. Non-2xx responses become *APIError. Errors never
// include request headers, so the API key can't leak into them.
func (c *Client) send(ctx context.Context, method string, u *url.URL, payload []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()

	var body io.Reader
	if payload != nil {
		body = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", method, u.Path, err)
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", userAgent)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", method, u.Path, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("%s %s: read response: %w", method, u.Path, err)
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return data, nil
	}
	return nil, decodeError(resp, data)
}

func decodeError(resp *http.Response, data []byte) *APIError {
	apiErr := &APIError{Status: resp.StatusCode, Message: http.StatusText(resp.StatusCode)}
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(data, &envelope) == nil && envelope.Error.Code != "" {
		apiErr.Code = envelope.Error.Code
		apiErr.Message = envelope.Error.Message
	}
	apiErr.retryAfter = defaultRetryAfter
	if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s >= 0 {
		apiErr.retryAfter = time.Duration(s) * time.Second
	}
	return apiErr
}
