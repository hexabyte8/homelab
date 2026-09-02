variable "aws_region" {
  description = "The AWS region for S3 bucket."
  type        = string
  default     = "us-east-1"
}

variable "s3_backup_bucket_name" {
  description = "Base S3 bucket name. Velero uses the same name with a -velero suffix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.s3_backup_bucket_name)) && length(var.s3_backup_bucket_name) >= 3 && length(var.s3_backup_bucket_name) <= 63
    error_message = "S3 bucket name must be lowercase, 3-63 characters, start and end with a letter or number, and can only contain lowercase letters, numbers, and hyphens (no underscores)."
  }
}
