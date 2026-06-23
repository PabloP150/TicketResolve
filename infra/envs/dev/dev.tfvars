environment  = "dev"
app_name     = "ticketresolve"
region       = "us-east-1"
architecture = "x86_64"

lambda_memory_default  = 256
lambda_timeout_default = 10

# --- Networking (Delivery 3) ---
vpc_cidr                  = "10.20.0.0/16"
availability_zones        = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs       = ["10.20.0.0/24", "10.20.1.0/24"]
private_app_subnet_cidrs  = ["10.20.10.0/24", "10.20.11.0/24"]
private_data_subnet_cidrs = ["10.20.20.0/24", "10.20.21.0/24"]
# Cost control (post Delivery-3): NAT Gateway apagado para evitar el costo fijo
# (~$32/mes). Las Lambdas corren fuera de la VPC, así que la demo E2E sigue
# funcionando. Poner en true para reactivar el egress de subnets privadas.
enable_nat_gateway = false
single_nat_gateway = true

# --- Network security (Delivery 3) ---
web_ingress_cidrs = ["0.0.0.0/0"]
http_port         = 80
https_port        = 443
app_port          = 443
db_port           = 5432

# --- Ingress (Delivery 3) ---
health_check_path = "/"

# --- Async messaging (Delivery 4) ---
# dev: shorter retention and a more forgiving redrive (5 attempts) — cheap to
# replay while iterating.
queue_visibility_timeout_seconds = 90
queue_message_retention_seconds  = 345600 # 4 days
queue_max_receive_count          = 5
dlq_message_retention_seconds    = 1209600 # 14 days

# --- Event-driven compute (Delivery 4) ---
event_source_batch_size                  = 10
event_source_max_batching_window_seconds = 5
event_source_bisect_on_error             = true
# null: account total concurrency is at the floor (10) and AWS requires >= 10
# unreserved, so a reservation cannot be set until a limit increase is granted.
consumer_reserved_concurrency = null

# --- Scheduled job (Delivery 4) ---
sla_sweep_schedule_expression = "rate(1 day)"
scheduler_timezone            = "America/Guatemala"

# NOTE: db_password is intentionally NOT set here. As of Delivery 5 the secret
# lives in Secrets Manager; Terraform only seeds an initial version from the
# var default, then ignores changes (the real value is managed in the console).

# Ephemeral env: allow destroy to empty buckets so teardown/rebuild is one command.
bucket_force_destroy = true

# --- TLS (Delivery 5, Deliverable D) ---
dns_subdomain = "grupo7.oyd.solid.com.gt"

# --- Observability (Delivery 5, Deliverable E) ---
log_retention_days       = 14
alarm_notification_email = "pablo.pineda@galileo.edu"

# Application notifications (US-05/US-06) — ticket escalations/resolutions and
# report-ready links. Same inbox as alarms for this environment.
notifications_email      = "pablo.pineda@galileo.edu"
lambda_error_threshold   = 1
apigw_5xx_threshold      = 1
dlq_depth_threshold      = 1
alarm_period_seconds     = 300
alarm_evaluation_periods = 1
# Near-$0 target: a low cap surfaces any unexpected spend (e.g. a forgotten
# NAT gateway) the moment it crosses 80%.
monthly_budget_usd                    = 5
budget_notification_threshold_percent = 80
