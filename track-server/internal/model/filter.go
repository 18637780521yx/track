package model

// EventFilter is a single AND condition on event JSON properties.
type EventFilter struct {
	// Source: "common" (common_properties) or "properties"
	Source string `json:"source"`
	// Field: JSON key, e.g. app_version
	Field string `json:"field"`
	// Op: eq | neq | contains
	Op string `json:"op"`
	// Value: comparison value (string)
	Value string `json:"value"`
}
