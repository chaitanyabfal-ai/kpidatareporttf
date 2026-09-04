output "bucket_name" {
  value = aws_s3_bucket.ilds.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.s3_events.arn
}

output "sqs_queue_url" {
  value = aws_sqs_queue.ilds.id
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.ilds.arn
}

output "ec2_role_name" {
  value = aws_iam_role.ec2.name
}

output "ec2_instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}

output "ec2_public_ip" {
  value       = var.ec2_launch ? aws_instance.kpi_worker[0].public_ip : null
  description = "Only set when ec2_launch = true."
}

output "ec2_ssh_command" {
  value = (
    var.ec2_launch && var.ec2_key_name != ""
    ? "ssh -i ${var.ec2_key_name}.pem ec2-user@${aws_instance.kpi_worker[0].public_ip}"
    : (var.ec2_launch
      ? "aws ssm start-session --target ${aws_instance.kpi_worker[0].id}"
      : null)
  )
}

output "dotenv_snippet" {
  description = "Paste into your local .env"
  value       = <<-EOT
    AWS_REGION=${var.aws_region}
    S3_BUCKET=${aws_s3_bucket.ilds.id}
    SQS_QUEUE_URL=${aws_sqs_queue.ilds.id}
  EOT
}
