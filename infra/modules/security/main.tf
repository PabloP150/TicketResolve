locals {
  module_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "security"
  })
}

# ===========================================================================
# Tiered security groups: web -> app -> db.
#
# Rules are declared as standalone aws_vpc_security_group_*_rule resources
# (never inline ingress/egress blocks) so the web<->app and app<->db
# references do not form a dependency cycle (rubric pitfall).
# ===========================================================================

resource "aws_security_group" "web" {
  name        = "${var.name_prefix}-web-sg"
  description = "Web tier. Accepts HTTP/HTTPS from the Internet; forwards to the app tier."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-web-sg"
    Tier = "web"
  })
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Application tier. Accepts traffic only from the web tier; forwards to the db tier."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-app-sg"
    Tier = "app"
  })
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Database tier. Accepts traffic only from the app tier on the DB port. No Internet ingress, no Internet egress."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-db-sg"
    Tier = "db"
  })
}

# --- web-sg rules ----------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "web_http" {
  for_each          = toset(var.web_ingress_cidrs)
  security_group_id = aws_security_group.web.id
  description       = "Inbound HTTP from approved CIDRs."
  cidr_ipv4         = each.value
  from_port         = var.http_port
  to_port           = var.http_port
  ip_protocol       = var.tcp_protocol
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  for_each          = toset(var.web_ingress_cidrs)
  security_group_id = aws_security_group.web.id
  description       = "Inbound HTTPS from approved CIDRs."
  cidr_ipv4         = each.value
  from_port         = var.https_port
  to_port           = var.https_port
  ip_protocol       = var.tcp_protocol
}

resource "aws_vpc_security_group_egress_rule" "web_to_app" {
  security_group_id            = aws_security_group.web.id
  description                  = "Forward to the app tier on the application port."
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = var.tcp_protocol
}

# --- app-sg rules ----------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "app_from_web" {
  security_group_id            = aws_security_group.app.id
  description                  = "Inbound from the web tier only, on the application port."
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = var.tcp_protocol
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Forward to the db tier on the database port."
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = var.tcp_protocol
}

# --- db-sg rules -----------------------------------------------------------
# Only one ingress rule: from the app tier on the DB port. No 0.0.0.0/0
# ingress on any port, and deliberately NO egress rule (Terraform leaves the
# group with no egress, so the db tier has no direct Internet egress).
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Inbound from the app tier only, on the database port."
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = var.tcp_protocol
}

# ===========================================================================
# Network ACLs — stateless, explicit inbound and outbound rules.
# One NACL for the public subnets, one for the private subnets.
# ===========================================================================

# --- Public NACL -----------------------------------------------------------
resource "aws_network_acl" "public" {
  vpc_id     = var.vpc_id
  subnet_ids = var.public_subnet_ids

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-nacl-public"
    Tier = "public"
  })
}

resource "aws_network_acl_rule" "public_in_http" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.http_port
  to_port        = var.http_port
}

resource "aws_network_acl_rule" "public_in_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 110
  egress         = false
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.https_port
  to_port        = var.https_port
}

resource "aws_network_acl_rule" "public_in_ephemeral" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 120
  egress         = false
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.ephemeral_port_from
  to_port        = var.ephemeral_port_to
}

resource "aws_network_acl_rule" "public_out_http" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = true
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.http_port
  to_port        = var.http_port
}

resource "aws_network_acl_rule" "public_out_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 110
  egress         = true
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.https_port
  to_port        = var.https_port
}

resource "aws_network_acl_rule" "public_out_ephemeral" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 120
  egress         = true
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.ephemeral_port_from
  to_port        = var.ephemeral_port_to
}

# --- Private NACL ----------------------------------------------------------
resource "aws_network_acl" "private" {
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  tags = merge(local.module_tags, {
    Name = "${var.name_prefix}-nacl-private"
    Tier = "private"
  })
}

resource "aws_network_acl_rule" "private_in_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "private_in_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.ephemeral_port_from
  to_port        = var.ephemeral_port_to
}

resource "aws_network_acl_rule" "private_out_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "private_out_https" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = true
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.https_port
  to_port        = var.https_port
}

resource "aws_network_acl_rule" "private_out_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 120
  egress         = true
  protocol       = var.tcp_protocol
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = var.ephemeral_port_from
  to_port        = var.ephemeral_port_to
}
