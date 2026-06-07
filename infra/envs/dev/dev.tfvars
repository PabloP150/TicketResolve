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
enable_nat_gateway        = false
single_nat_gateway        = true

# --- Network security (Delivery 3) ---
web_ingress_cidrs = ["0.0.0.0/0"]
http_port         = 80
https_port        = 443
app_port          = 443
db_port           = 5432

# --- Ingress (Delivery 3) ---
health_check_path = "/"
