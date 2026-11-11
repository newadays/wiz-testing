# ---------------------------------------------------------------------------------------------
# Cloud Native Security requirements: control-plane audit logging, preventative and detective controls.
# ---------------------------------------------------------------------------------------------

# 1. AUDIT LOGGING. Admin Activity logs are always on. This turns on Data Access logs for every service,
#    so reads of the public bucket, Secret Manager accesses, and metadata reads are all recorded.
resource "google_project_iam_audit_config" "all" {
  project = var.project
  service = "allServices"
  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

# Keep the audit trail somewhere the over-privileged VM identity cannot tamper with: a locked log bucket.
resource "google_logging_project_bucket_config" "audit" {
  project        = var.project
  location       = var.region # the lab org's gcp.resourceLocations policy refuses "global"
  bucket_id      = "audit-trail"
  retention_days = 90
  locked         = false # set true for production (irreversible)
}

resource "google_logging_project_sink" "audit" {
  name                   = "audit-to-locked-bucket"
  destination            = "logging.googleapis.com/projects/${var.project}/locations/${google_logging_project_bucket_config.audit.location}/buckets/${google_logging_project_bucket_config.audit.bucket_id}"
  filter                 = "logName:\"cloudaudit.googleapis.com\""
  unique_writer_identity = true
}

# 2. PREVENTATIVE CONTROLS.
# 2a. Org Policy constraints at project level (needs orgpolicy.policyAdmin; off by default for CloudLabs accounts).
#     These are the controls a production project would have; applying them here would block the intentional
#     weaknesses, which is exactly the demo: enable one, re-run terraform plan, watch the public bucket binding fail.
resource "google_project_organization_policy" "no_public_buckets" {
  count      = var.enable_org_policies ? 1 : 0
  project    = var.project
  constraint = "storage.publicAccessPrevention"
  boolean_policy { enforced = true }
}

resource "google_project_organization_policy" "no_sa_keys" {
  count      = var.enable_org_policies ? 1 : 0
  project    = var.project
  constraint = "iam.disableServiceAccountKeyCreation"
  boolean_policy { enforced = true }
}

resource "google_project_organization_policy" "no_external_ips" {
  count      = var.enable_org_policies ? 1 : 0
  project    = var.project
  constraint = "compute.vmExternalIpAccess"
  list_policy {
    allow { values = ["projects/${var.project}/zones/${var.zone}/instances/mongo-vm"] } # allowlist the one exception
  }
}

# 2b. Binary Authorization: the cluster only runs images that CI signed. Enforced in the prod namespace demo
#     (security/binauthz-policy.yaml); the cluster flag below turns the admission controller on.
#     Kept as a separate apply step so the first deploy is not blocked before the attestor exists.

# 3. DETECTIVE CONTROLS: log-based alerts on the things an attacker would do first in this environment.
resource "google_monitoring_notification_channel" "email" {
  display_name = "wiz-exercise alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

locals {
  detections = {
    firewall-opened-to-world = {
      doc    = "A firewall rule was created or changed to allow 0.0.0.0/0. In this environment that is how SSH became public."
      filter = <<-EOT
        logName:"cloudaudit.googleapis.com/activity"
        protoPayload.methodName=~"compute.firewalls.(insert|patch|update)"
        protoPayload.request.sourceRanges:"0.0.0.0/0"
      EOT
    }
    bucket-made-public = {
      doc    = "A bucket IAM policy was changed to include allUsers or allAuthenticatedUsers."
      filter = <<-EOT
        logName:"cloudaudit.googleapis.com/activity"
        protoPayload.methodName="storage.setIamPermissions"
        (protoPayload.serviceData.policyDelta.bindingDeltas.member="allUsers" OR protoPayload.serviceData.policyDelta.bindingDeltas.member="allAuthenticatedUsers")
      EOT
    }
    ssh-login-mongo-vm = {
      doc    = "An SSH session was accepted on the Mongo VM (from the Ops Agent's auth.log stream)."
      filter = <<-EOT
        resource.type="gce_instance"
        logName:"auth"
        jsonPayload.message=~"Accepted (publickey|password)" OR textPayload=~"Accepted (publickey|password)"
      EOT
    }
    iam-owner-or-editor-granted = {
      doc    = "A principal was granted roles/owner or roles/editor on the project."
      filter = <<-EOT
        logName:"cloudaudit.googleapis.com/activity"
        protoPayload.methodName="SetIamPolicy"
        (protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/owner" OR protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/editor")
        protoPayload.serviceData.policyDelta.bindingDeltas.action="ADD"
      EOT
    }
    k8s-clusterrolebinding-cluster-admin = {
      doc    = "A ClusterRoleBinding to cluster-admin was created in GKE (the exercise's own weakness, caught by the control plane audit log)."
      filter = <<-EOT
        protoPayload.serviceName="k8s.io"
        protoPayload.methodName="io.k8s.authorization.rbac.v1.clusterrolebindings.create"
        protoPayload.request.roleRef.name="cluster-admin"
      EOT
    }
    k8s-exec-into-pod = {
      doc    = "Someone ran kubectl exec. Interactive access to a cluster-admin pod is the first step of the attack path."
      filter = <<-EOT
        protoPayload.serviceName="k8s.io"
        protoPayload.methodName="io.k8s.core.v1.pods.exec.create"
      EOT
    }
  }
}

resource "google_logging_metric" "detections" {
  for_each    = local.detections
  name        = "wiz/${each.key}"
  description = each.value.doc
  filter      = each.value.filter
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "detections" {
  for_each     = local.detections
  display_name = "wiz: ${each.key}"
  combiner     = "OR"
  documentation {
    content = each.value.doc
  }
  conditions {
    display_name = each.key
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.detections[each.key].name}\" resource.type=\"${local.detection_resource_types[each.key]}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.id]
  alert_strategy {
    auto_close = "1800s"
  }
}

# Monitored resource type each log-based metric is written against; the alert filter must name it.
# project and gce_firewall_rule are not Monitoring resource types, so those metrics land on global.
locals {
  detection_resource_types = {
    firewall-opened-to-world             = "global"
    bucket-made-public                   = "gcs_bucket"
    iam-owner-or-editor-granted          = "global"
    k8s-clusterrolebinding-cluster-admin = "k8s_cluster"
    k8s-exec-into-pod                    = "k8s_cluster"
    ssh-login-mongo-vm                   = "gce_instance"
  }
}
