package service

// 约定埋点事件名，ingest 时用于更新衍生表。
const (
	EventAppFirstOpen        = "app_first_open"
	EventUserSignup          = "user_signup"
	EventPaymentSuccess      = "payment_success"
	EventSubscriptionStart   = "subscription_start"
	EventSubscriptionRenew   = "subscription_renew"
	EventSubscriptionCancel  = "subscription_cancel"
)
