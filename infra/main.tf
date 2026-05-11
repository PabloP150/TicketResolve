resource "aws_s3_bucket" "bootstrap" {
  bucket = "${var.app_name}-${var.environment}-${var.bucket_name}"

  tags = {
    Name         = "${var.app_name}-${var.environment}-${var.bucket_name}"
    Environment  = var.environment
    Application  = var.app_name
    Region       = var.region
    Architecture = var.architecture
    Purpose      = "delivery-1-bootstrap"
  }
}
