# S3 bucket for game server backups
resource "aws_s3_bucket" "gameserver_backups" {
  bucket = var.s3_backup_bucket_name

  tags = {
    Name        = "Game Server Backups"
    Environment = "homelab"
    Purpose     = "backups"
  }
}

# Enable versioning for backup protection
resource "aws_s3_bucket_versioning" "gameserver_backups" {
  bucket = aws_s3_bucket.gameserver_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "gameserver_backups" {
  bucket = aws_s3_bucket.gameserver_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "gameserver_backups" {
  bucket = aws_s3_bucket.gameserver_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule to manage backup retention
resource "aws_s3_bucket_lifecycle_configuration" "gameserver_backups" {
  bucket = aws_s3_bucket.gameserver_backups.id

  rule {
    id     = "delete-old-backups"
    status = "Enabled"

    # Apply to all objects in the bucket
    filter {}

    # Move to Glacier after 30 days
    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    # Delete after 90 days
    expiration {
      days = 90
    }

    # Clean up old versions
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
