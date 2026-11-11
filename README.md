# Wiz Technical Exercise — Tasky on GKE

A two-tier web app built, deployed to **Google Cloud (GKE)** entirely through Terraform and two CI/CD pipelines. The environment contains the intentional weaknesses the exercise requires, and a layer of preventative + detective controls that catch them.

```
Internet ──▶ GKE Ingress (HTTP(S) LB) ──▶ Tasky pods (private subnet)
                                               │  MONGODB_URI (K8s Secret)
                                               ▼
                                     MongoDB 4.4 on Ubuntu 20.04 VM (public subnet)
                                               │  daily mongodump
                                               ▼
                                     GCS bucket (public-read) — DB backups
```

| Layer | Choice |
| --- | --- |
| App | `tasky` — Python/Flask todo list, MongoDB-backed, image re-built in CI |
| Container | Multi-stage, non-root, `wizexercise.txt` baked into the image layer |
| Orchestration | Private GKE cluster (Dataplane V2, Workload Identity, shielded nodes) |
| Database | MongoDB 4.4 (EOL) on an Ubuntu 20.04 VM, auth required, reachable only from the cluster ranges |
| Backups | Daily `mongodump` → public-readable GCS bucket |
| IaC | Terraform, remote state in GCS |
| CI/CD | GitHub Actions: `iac.yml` (plan/apply) and `app.yml` (build/scan/push/deploy), OIDC auth, no keys |
| Security | Audit logging, Checkov/Trivy/gitleaks gates, org-policy preventative controls, log-based detective alerts |

## Layout

```
app/          Flask app, Dockerfile, tests, wizexercise.txt
k8s/          Namespace, RBAC, Deployment, Service, Ingress, Kustomization
terraform/    network, mongo-vm, bucket, gke, registry, cicd, security, outputs
security/     skip documentation + hardened prod namespace, binauthz policy
docs/         build runbook, security findings, demo script
.github/      two pipelines, CODEOWNERS, dependabot
```

See `docs/BUILD.md` to deploy, `docs/SECURITY-FINDINGS.md` for the weakness/consequence/remediation table, and `docs/DEMO.md` for the live walkthrough order.
