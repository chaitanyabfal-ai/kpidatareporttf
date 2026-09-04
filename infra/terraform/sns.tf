resource "aws_sns_topic" "s3_events" {
  name = var.sns_s3_topic_name
}

data "aws_iam_policy_document" "sns_s3_publish" {
  statement {
    sid     = "AllowS3Publish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sns_topic.s3_events.arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.ilds.arn]
    }
  }
}

resource "aws_sns_topic_policy" "s3_events" {
  arn    = aws_sns_topic.s3_events.arn
  policy = data.aws_iam_policy_document.sns_s3_publish.json
}

# Optional alerts topic — only created if an email is supplied.
resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = var.sns_alert_topic_name
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
  # Terraform can't auto-confirm an email subscription — check your inbox
  # after `terraform apply` and click the confirmation link.
}
