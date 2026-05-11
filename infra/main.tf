resource "aws_s3_bucket" "bootstrap" {
  bucket = "${var.bucket_name}-${var.environment}"

  tags = {
    Name         = "${var.bucket_name}-${var.environment}"
    Environment  = var.environment
    Application  = var.app_name
    Region       = var.region
    Architecture = var.architecture
    Purpose      = "delivery-1-bootstrap"
  }
}
