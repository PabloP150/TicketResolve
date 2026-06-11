environment  = "staging"
app_name     = "ticketresolve"
region       = "us-east-1"
architecture = "x86_64"

# DIFFERS from dev (256): staging runs heavier memory to mirror a pre-prod load
# profile.
lambda_memory_default  = 512
lambda_timeout_default = 10

# --- Networking (Delivery 3) ---
# DIFFERS from dev (10.20.0.0/16): a separate CIDR so the two environments could
# be peered or audited side by side without overlap.
vpc_cidr                  = "10.30.0.0/16"
availability_zones        = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs       = ["10.30.0.0/24", "10.30.1.0/24"]
private_app_subnet_cidrs  = ["10.30.10.0/24", "10.30.11.0/24"]
private_data_subnet_cidrs = ["10.30.20.0/24", "10.30.21.0/24"]
# NAT off in both environments for cost control; Lambdas run outside the VPC.
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
# DIFFERS from dev: staging keeps messages the full 14 days and quarantines a
# poison message sooner (3 attempts vs 5) so pre-prod surfaces failures faster.
queue_visibility_timeout_seconds = 90
queue_message_retention_seconds  = 1209600 # 14 days (dev: 4 days)
queue_max_receive_count          = 3       # dev: 5
dlq_message_retention_seconds    = 1209600

# --- Event-driven compute (Delivery 4) ---
event_source_batch_size                  = 10
event_source_max_batching_window_seconds = 5
event_source_bisect_on_error             = true
# null for the same account-limit reason as dev (total concurrency floor of 10).
consumer_reserved_concurrency = null

# --- Scheduled job (Delivery 4) ---
# DIFFERS from dev (rate(1 day)): staging sweeps twice a day.
sla_sweep_schedule_expression = "rate(12 hours)"
scheduler_timezone            = "America/Guatemala"

# NOTE: db_password is injected from the GitHub Environment secret
# STAGING_DB_PASSWORD as TF_VAR_db_password — never committed here.
