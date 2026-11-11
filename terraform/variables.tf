variable "project" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "candidate_name" {
  description = "Used for labels and the backup bucket name"
  type        = string
  default     = "gbenga"
}
variable "operator_cidr" {
  description = "Your laptop's IP in CIDR form, allowed to reach the GKE control plane"
  type        = string
}
variable "github_repo" {
  description = "owner/repo allowed to deploy through Workload Identity Federation"
  type        = string
}
variable "mongo_machine_type" {
  type    = string
  default = "e2-small"
}
variable "alert_email" {
  description = "Where detective-control alerts go"
  type        = string
}
variable "enable_org_policies" {
  description = "Set true when the account can set project-level org policy constraints (needs orgpolicy.policyAdmin)"
  type        = bool
  default     = false
}

locals {
  labels = { exercise = "wiz", owner = var.candidate_name, managed_by = "terraform" }
}
