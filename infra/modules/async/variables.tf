variable "queue_name_prefix" {
  description = "Prefix for the SQS queue names. The module appends '-events' to the main queue and '-events-dlq' to the dead-letter queue, so a prefix of 'ticketresolve-dev' yields 'ticketresolve-dev-events' and 'ticketresolve-dev-events-dlq'."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "How long a message stays invisible to other consumers after one consumer receives it. Should be >= the consumer Lambda timeout so a slow invocation does not cause a second delivery before the first finishes. Range 0-43200."
  type        = number

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 0 and 43200 (12 hours)."
  }
}

variable "message_retention_seconds" {
  description = "How long the main queue keeps a message that is never deleted, in seconds. Range 60 (1 min) to 1209600 (14 days)."
  type        = number

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "max_receive_count" {
  description = "Number of times a single message may be received (and fail to be deleted) before the redrive_policy moves it to the dead-letter queue. A value of 5 gives the consumer five attempts before a poison message is quarantined."
  type        = number

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "dlq_message_retention_seconds" {
  description = "How long the dead-letter queue keeps a failed message, in seconds. Set longer than the main queue retention so operators have time to inspect and replay poison messages. Range 60 to 1209600 (14 days)."
  type        = number

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "dlq_message_retention_seconds must be between 60 and 1209600 (14 days)."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource created by this module. The module also sets Environment, ManagedBy and Module tags via the caller."
  type        = map(string)
  default     = {}
}
