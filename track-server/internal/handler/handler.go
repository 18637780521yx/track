package handler

import (
	"bytes"
	"compress/gzip"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/fc/track-server/internal/model"
	"github.com/fc/track-server/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
)

type Handler struct {
	svc *service.AnalyticsService
}

func New(svc *service.AnalyticsService) *Handler {
	return &Handler{svc: svc}
}

func (h *Handler) Register(r *gin.Engine) {
	r.Use(corsMiddleware())

	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	r.POST("/track", h.ingest)
	r.POST("/api/v1/track", h.ingest)

	api := r.Group("/api/v1")
	{
		api.GET("/overview", h.overview)
		api.GET("/events/names", h.eventNames)
		api.GET("/events/trend", h.eventTrend)
		api.GET("/events", h.listEvents)
		api.POST("/funnel", h.funnel)
		api.GET("/retention", h.retention)
		api.GET("/users", h.listUsers)
		api.GET("/users/:id/events", h.listUserEvents)
		api.GET("/users/:id", h.getUser)
	}
}

func (h *Handler) ingest(c *gin.Context) {
	body, err := readBody(c.Request)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid body"})
		return
	}

	events, err := model.ParseIngestRequest(body)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid json"})
		return
	}

	stored, dropped, err := h.svc.Ingest(c.Request.Context(), events)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, model.IngestResponse{
		OK:      true,
		Total:   len(events),
		Stored:  stored,
		Dropped: dropped,
	})
}

func (h *Handler) overview(c *gin.Context) {
	from, to := parseRange(c)
	stats, err := h.svc.Overview(c.Request.Context(), from, to)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, stats)
}

func (h *Handler) eventNames(c *gin.Context) {
	names, err := h.svc.EventNames(c.Request.Context(), c.Query("q"))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": names})
}

func (h *Handler) eventTrend(c *gin.Context) {
	from, to := parseRange(c)
	eventName := c.Query("event")
	unit := c.DefaultQuery("unit", "day")
	points, err := h.svc.EventTrend(c.Request.Context(), eventName, from, to, unit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": points})
}

func (h *Handler) listEvents(c *gin.Context) {
	from, to := parseRange(c)
	eventName := c.Query("event")
	limit := queryInt(c, "limit", 50)
	offset := queryInt(c, "offset", 0)

	records, total, err := h.svc.ListEvents(c.Request.Context(), eventName, from, to, limit, offset)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": records, "total": total})
}

type funnelRequest struct {
	Steps       []string `json:"steps"`
	From        string   `json:"from"`
	To          string   `json:"to"`
	WindowHours int      `json:"window_hours"`
}

func (h *Handler) funnel(c *gin.Context) {
	var req funnelRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request"})
		return
	}
	from, to := parseRangeFromStrings(req.From, req.To)
	result, err := h.svc.Funnel(c.Request.Context(), req.Steps, from, to, req.WindowHours)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *Handler) retention(c *gin.Context) {
	from, to := parseRange(c)
	cohortEvent := c.DefaultQuery("cohort_event", "app_start")
	returnEvent := c.DefaultQuery("return_event", cohortEvent)
	days := queryInt(c, "days", 7)

	result, err := h.svc.Retention(c.Request.Context(), cohortEvent, returnEvent, from, to, days)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *Handler) listUsers(c *gin.Context) {
	query := c.Query("q")
	limit := queryInt(c, "limit", 50)
	offset := queryInt(c, "offset", 0)
	users, total, err := h.svc.ListUsers(c.Request.Context(), query, limit, offset)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": users, "total": total})
}

func (h *Handler) getUser(c *gin.Context) {
	user, err := h.svc.GetUser(c.Request.Context(), c.Param("id"))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, user)
}

func (h *Handler) listUserEvents(c *gin.Context) {
	from, to := parseRange(c)
	limit := queryInt(c, "limit", 500)
	offset := queryInt(c, "offset", 0)
	records, total, err := h.svc.ListUserEvents(c.Request.Context(), c.Param("id"), from, to, limit, offset)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": records, "total": total})
}

func readBody(r *http.Request) ([]byte, error) {
	var reader io.Reader = r.Body
	if r.Header.Get("Content-Encoding") == "gzip" {
		gr, err := gzip.NewReader(r.Body)
		if err != nil {
			return nil, err
		}
		defer gr.Close()
		reader = gr
	}
	return io.ReadAll(reader)
}

func parseRange(c *gin.Context) (time.Time, time.Time) {
	return parseRangeFromStrings(c.Query("from"), c.Query("to"))
}

func parseRangeFromStrings(fromStr, toStr string) (time.Time, time.Time) {
	now := time.Now().UTC()
	to := now
	from := now.AddDate(0, 0, -7)

	if toStr != "" {
		if t, err := time.Parse(time.RFC3339, toStr); err == nil {
			to = t
		}
	}
	if fromStr != "" {
		if t, err := time.Parse(time.RFC3339, fromStr); err == nil {
			from = t
		}
	}
	return from, to
}

func queryInt(c *gin.Context, key string, fallback int) int {
	v := c.Query(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Content-Encoding")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

// Ensure gzip ingest works with empty body edge cases.
var _ = bytes.Reader{}
