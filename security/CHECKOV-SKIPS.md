# Checkov checks skipped on purpose

The IaC pipeline fails on every Checkov finding except the ones listed here. The same list is used in both places Checkov runs in `.github/workflows/iac.yml`: `skip_check` in the "Scan IaC" job (static scan of `terraform/`), and `--skip-check` in the "Scan the plan" step.

Verified locally with Checkov 3.3.30 (run inside `terraform/`): with no skips, 17 failures; with this list, 0 failures, exit 0.

```bash
checkov -d . --framework terraform --compact --quiet --skip-check <the list in iac.yml>
```

## 1. Required by the exercise (intentional weaknesses)

| Check ID | What it flags | Resource | Exercise requirement |
| --- | --- | --- | --- |
| CKV_GCP_2 | Firewall allows SSH from 0.0.0.0/0 | `google_compute_firewall.mongo_ssh_public` | SSH exposed to the public internet |
| CKV_GCP_40 | Compute instance has a public IP | `google_compute_instance.mongo` | VM in a public subnet |
| CKV_GCP_32 | "Block project-wide SSH keys" not enabled | `google_compute_instance.mongo` | SSH exposed to the public internet |
| CKV_GCP_39 | Shielded VM not enabled | `google_compute_instance.mongo` | Outdated, exposed VM |
| CKV_GCP_28 | Bucket is anonymously or publicly accessible | `google_storage_bucket_iam_member.public_read` | Backups publicly readable and listable |
| CKV_GCP_114 | Public access prevention not enforced | `google_storage_bucket.backups` | Backups publicly readable and listable |

The over-privileged VM service account (`compute.admin` + `storage.admin`) and the `cluster-admin` binding are also required weaknesses, but Checkov raises nothing for them: the first is a role choice it does not judge, and the second is in `k8s/rbac.yaml`, which this Terraform scan does not cover.

## 2. Lab scope (accepted, with the production control noted)

| Check ID | What it flags | Resource | Why accepted here / production control |
| --- | --- | --- | --- |
| CKV_GCP_62 | Bucket has no access logging | `google_storage_bucket.backups` | Data Access audit logs (`security.tf`) already record every read. Production: also enable usage logs |
| CKV_GCP_38 | VM disk not encrypted with a customer-supplied key (CSEK) | `google_compute_instance.mongo` | Google-managed encryption is on. Production: CMEK through Cloud KMS |
| CKV_GCP_84 | Artifact Registry not encrypted with a customer key | `google_artifact_registry_repository.apps` | Same as above |
| CKV_GCP_65 | GKE RBAC not managed with Google Groups | `google_container_cluster.wiz` | The lab org has no Workspace groups. Production: Google Groups for RBAC |
| CKV_GCP_66 | Binary Authorization not enabled on the cluster | `google_container_cluster.wiz` | Turned on as a separate demo step, so the first deploy is not blocked before the attestor exists |
| CKV_GCP_41 | Service Account User granted at project level | `google_project_iam_member.iac["roles/iam.serviceAccountUser"]` | The Terraform CI identity must attach service accounts to the VM and the nodes. Production: grant it on those specific service accounts only |
| CKV_GCP_49 | Roles that manage or impersonate service accounts at project level | `google_project_iam_member.iac[...serviceAccountAdmin / serviceAccountUser]` | The CI identity creates the service accounts. Production: separate bootstrap identity, scoped grants |

## 3. False positives (the control is in place, Checkov cannot see it)

| Check ID | What it flags | Resource | Why it is a false positive |
| --- | --- | --- | --- |
| CKV_GCP_12 | Network Policy not enabled | `google_container_cluster.wiz` | `datapath_provider = "ADVANCED_DATAPATH"` (Dataplane V2) enforces NetworkPolicy natively; the `network_policy` block Checkov looks for is not allowed with it |
| CKV_GCP_69 | GKE Metadata Server not enabled | `google_container_cluster.wiz` | It is set where it applies: `workload_metadata_config { mode = "GKE_METADATA" }` on the node pool. The cluster has no default pool |
| CKV_GCP_125 | GitHub Actions OIDC trust not restricted | `google_iam_workload_identity_pool_provider.github` | `attribute_condition = "assertion.repository == '${var.github_repo}'"` restricts it to this repo; Checkov cannot resolve the variable |

## 4. Fixed in Terraform (no longer skipped)

These were real gaps, not exercise requirements, so they are fixed rather than skipped. Checkov now enforces them.

| Check ID | What it flagged | Fix | File |
| --- | --- | --- | --- |
| CKV_GCP_13 | Client certificate auth not explicitly disabled | `master_auth { client_certificate_config { issue_client_certificate = false } }` | `gke.tf` |
| CKV_GCP_61 | Intranode visibility not enabled | `enable_intranode_visibility = true` | `gke.tf` |
| CKV_GCP_26 | No VPC flow logs on the public subnet | `log_config` (5-min aggregation, 50% sampling, all metadata), same as the private subnet | `network.tf` |
| CKV_GCP_74 | Private Google Access off on the public subnet | `private_ip_google_access = true` | `network.tf` |
| CKV_GCP_78 | Bucket versioning not enabled | `versioning { enabled = true }`, plus a lifecycle rule that deletes noncurrent versions after 14 days | `bucket.tf` |

## Removed from the old list

| Check ID | Why removed |
| --- | --- |
| CKV_GCP_29 | Passes (uniform bucket-level access is on); the skip did nothing |
| CKV_GCP_35 | Passes (serial port access is off); the skip did nothing |
| CKV2_GCP_5 | Passes. It checks that audit logging covers all services, which `security.tf` does; the old description ("over-privileged service account") was wrong |

Everything else stays enforced: private GKE nodes, dedicated node service account, shielded nodes, Workload Identity, control-plane and data-access audit logging, Cloud NAT, VPC flow logs on both subnets, intranode visibility, no client certificates, and versioned backups.
