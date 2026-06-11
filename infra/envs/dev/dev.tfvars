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

# NOTE: db_password is intentionally NOT set here. It is injected at apply time
# from the GitHub Environment secret DEV_DB_PASSWORD as TF_VAR_db_password.

# Ephemeral env: allow destroy to empty buckets so teardown/rebuild is one command.
bucket_force_destroy = true
