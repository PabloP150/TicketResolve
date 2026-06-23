output "queue_url" {
  description = "URL of the main SQS queue. Injected into the producer Lambda (api-tickets) so it can SendMessage, and consumed by the event source mapping."
  value       = aws_sqs_queue.main.id
}

output "queue_arn" {
  description = "ARN of the main SQS queue. Used to scope the producer's sqs:SendMessage and the consumer's sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes IAM statements, and as the event_source_arn of the event source mapping."
  value       = aws_sqs_queue.main.arn
}

output "queue_name" {
  description = "Name of the main SQS queue. Useful for CLI introspection (aws sqs get-queue-attributes) in evidence steps."
  value       = aws_sqs_queue.main.name
}

output "dlq_url" {
  description = "URL of the dead-letter queue. Used to inspect the depth of quarantined messages (aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages)."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead-letter queue. Referenced by the main queue's redrive_policy and available for DLQ alarm targets in Delivery 5."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Name of the dead-letter queue. Used as the QueueName dimension for the DLQ-depth alarm and dashboard widget."
  value       = aws_sqs_queue.dlq.name
}
