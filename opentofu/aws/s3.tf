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

# Dedicated Velero bucket. Keeping cluster backups separate avoids the game
# server lifecycle policy archiving active Velero objects to Glacier.
resource "aws_s3_bucket" "velero_backups" {
  bucket = "daggertooth-cluster-backups"

  tags = {
    Name        = "Velero Cluster Backups"
    Environment = "homelab"
    Purpose     = "cluster-disaster-recovery"
  }
}

resource "aws_s3_bucket_versioning" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  rule {
    id     = "clean-up-velero-versions"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Velero receives a dedicated IAM identity with access limited to its bucket.
resource "aws_iam_user" "velero" {
  name = "homelab-velero"
}

data "aws_iam_policy_document" "velero" {
  statement {
    sid = "ListVeleroBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.velero_backups.arn]
  }

  statement {
    sid = "ManageVeleroBackups"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.velero_backups.arn}/*"]
  }
}

resource "aws_iam_user_policy" "velero" {
  name   = "homelab-velero-s3"
  user   = aws_iam_user.velero.name
  policy = data.aws_iam_policy_document.velero.json
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}

output "velero_backup_bucket_name" {
  description = "S3 bucket used by Velero for cluster backups."
  value       = aws_s3_bucket.velero_backups.id
}

output "velero_credentials_file" {
  description = "AWS credentials file synchronized to BWS for Velero."
  sensitive   = true
  value       = <<-EOT
    [default]
    aws_access_key_id=${aws_iam_access_key.velero.id}
    aws_secret_access_key=${aws_iam_access_key.velero.secret}
  EOT
}
