resource "aws_sqs_queue" "ilds" {
  name                       = var.queue_name
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20     # long polling
}

data "aws_iam_policy_document" "sqs_sns_send" {
  statement {
    sid     = "AllowSNSSendMessage"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    resources = [aws_sqs_queue.ilds.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.s3_events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "ilds" {
  queue_url = aws_sqs_queue.ilds.id
  policy    = data.aws_iam_policy_document.sqs_sns_send.json
}

resource "aws_sns_topic_subscription" "sqs" {
  topic_arn            = aws_sns_topic.s3_events.arn
  protocol              = "sqs"
  endpoint              = aws_sqs_queue.ilds.arn
  raw_message_delivery  = false

  # The subscription must exist with a matching queue policy already in
  # place, or SNS's auto-confirm handshake can fail and leave it stuck in
  # PendingConfirmation (a failure mode we hit debugging this pipeline
  # by hand — see SECURITY.md / RUNBOOK.md troubleshooting section).
  depends_on = [aws_sqs_queue_policy.ilds]
}

# S3 -> SNS event notification. NOTE: put_bucket_notification_configuration
# is a full-replace API — if anything else (a script, the console, a second
# Terraform config) sets bucket notifications on this same bucket outside
# this file, whichever was applied last silently wins. Keep this the single
# source of truth for this bucket's notification config.
resource "aws_s3_bucket_notification" "ilds" {
  bucket = aws_s3_bucket.ilds.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sns_topic_policy.s3_events]
}
