variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "S3 bucket name. Leave null to auto-generate as '<account_id>-ilds-sensor-data'."
  type        = string
  default     = null
}

variable "queue_name" {
  description = "SQS queue name."
  type        = string
  default     = "ilds_queue_1"
}

variable "sns_s3_topic_name" {
  description = "SNS topic name for S3 event notifications."
  type        = string
  default     = "ilds-s3-events"
}

variable "sns_alert_topic_name" {
  description = "SNS topic name for operational alerts (only created if alert_email is set)."
  type        = string
  default     = "ilds-alerts"
}

variable "alert_email" {
  description = "Email address to subscribe to the alerts topic. Leave empty to skip creating it."
  type        = string
  default     = ""
}

variable "bfa_prefixes" {
  description = "Sensor prefixes to pre-create as S3 'folders'. Must match SENSOR_PREFIXES in config/aws_config.py."
  type        = list(string)
  default     = ["BFA3/", "BFA8/", "BFA12/"]
}

# --- EC2 (optional) ---

variable "ec2_launch" {
  description = "Whether to launch the EC2 KPI-poller worker instance."
  type        = bool
  default     = false
}

variable "ec2_instance_type" {
  description = "EC2 instance type for the worker."
  type        = string
  default     = "t3.micro"
}

variable "ec2_key_name" {
  description = "Existing EC2 key pair name for SSH access. Leave empty to launch without one (use SSM Session Manager instead)."
  type        = string
  default     = ""
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH into the worker (only relevant if ec2_key_name is set). Restrict this to your own IP/VPN in production — 0.0.0.0/0 is the same broad rule the bash script used, kept as the default for parity, not as a recommendation."
  type        = string
  default     = "0.0.0.0/0"
}

variable "repo_url" {
  description = "Git URL the EC2 instance clones on boot."
  type        = string
  default     = "https://github.com/chaitanyabfal-ai/kpidatareporttf.git"
}

variable "deploy_user" {
  description = "Linux user the app runs as on EC2 — must match User= in the systemd unit files."
  type        = string
  default     = "ec2-user"
}
