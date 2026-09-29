package service

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/fc/track-server/internal/model"
)

var safeJSONKey = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

var commonFieldAllow = map[string]bool{
	"environment":              true,
	"build_mode":               true,
	"sdk_version":              true,
	"locale":                   true,
	"language":                 true,
	"timezone_offset_hours":    true,
	"app_version":              true,
	"app_build":                true,
	"app_name":                 true,
	"app_package":              true,
	"device_os":                true,
	"device_os_version":        true,
	"device_model":             true,
	"device_brand":             true,
	"network_type":             true,
}

// appendEventFilters adds AND conditions for JSONB property filters.
// startIdx is the next $N placeholder index (1-based for pgx).
func appendEventFilters(filters []model.EventFilter, startIdx int) (clause string, args []any, nextIdx int) {
	nextIdx = startIdx
	var parts []string

	for _, f := range filters {
		source := strings.TrimSpace(f.Source)
		field := strings.TrimSpace(f.Field)
		op := strings.ToLower(strings.TrimSpace(f.Op))
		value := strings.TrimSpace(f.Value)

		if field == "" || value == "" {
			continue
		}
		if !safeJSONKey.MatchString(field) {
			continue
		}

		col := "common_properties"
		switch source {
		case "properties", "prop", "event":
			col = "properties"
		case "common", "common_properties", "":
			if !commonFieldAllow[field] && source != "" {
				// still allow common fields not in allowlist if key is safe
			}
			col = "common_properties"
		default:
			continue
		}

		expr := fmt.Sprintf("COALESCE(%s->>'%s', '')", col, field)

		switch op {
		case "eq", "equal", "=":
			parts = append(parts, fmt.Sprintf("%s = $%d", expr, nextIdx))
			args = append(args, value)
			nextIdx++
		case "neq", "not_equal", "!=":
			parts = append(parts, fmt.Sprintf("%s <> $%d", expr, nextIdx))
			args = append(args, value)
			nextIdx++
		case "contains", "like":
			parts = append(parts, fmt.Sprintf("%s ILIKE $%d", expr, nextIdx))
			args = append(args, "%"+value+"%")
			nextIdx++
		default:
			continue
		}
	}

	if len(parts) == 0 {
		return "", nil, nextIdx
	}
	return " AND " + strings.Join(parts, " AND "), args, nextIdx
}
