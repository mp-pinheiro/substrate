terraform {
  required_version = ">= 1.0.0"
}

variable "sample_input" {
  type        = string
  description = "matrix sample"
  default     = "ok"
}

output "sample_output" {
  description = "matrix sample"
  value       = var.sample_input
}
