# Security findings — intended weaknesses, consequences, remediation

The exercise requires these misconfigurations so the security tooling has something to find. Each row is what a CNAPP (such as Wiz) would surface, why it matters, and how it is fixed.

| # | Weakness (where) | Why it matters | Remediation |
| --- | --- | --- | --- |
| 1 | **SSH open to 0.0.0.0/0** (`mongo-allow-ssh-public`) | Anyone can reach the VM's sshd; brute force / 0-day exposure | Restrict source ranges to a bastion/IAP; use IAP TCP forwarding instead of a public port |
| 2 | **Over-privileged VM identity** (compute.admin + storage.admin) | Any code-exec on the VM can create VMs, read every bucket — lateral movement and persistence | Least-privilege SA: only the one bucket's objectCreator |
| 3 | **Outdated OS + DB** (Ubuntu 20.04, MongoDB 4.4 EOL) | Known CVEs, no security patches | Patched OS image, supported MongoDB, OS Config patch management |
| 4 | **Public-read + listable backup bucket** | DB backups (all app data) downloadable by anyone who guesses/lists the bucket | Remove `allUsers`; enforce `publicAccessPrevention`; CMEK |
| 5 | **Cluster-admin bound to the app ServiceAccount** (`k8s/rbac.yaml`) | Container RCE = full cluster control: read all Secrets, schedule privileged pods, reach node metadata | Namespace-scoped Role with only what the app needs; no token automount |
| 6 | **App pod reachable path to an over-privileged VM** | Combined with #2 and #5, a single app compromise chains to cloud-account takeover | Break any one link; this is the "toxic combination" a graph highlights |

## The toxic combination (the story for the panel)
Individually these are medium findings. Chained, they are one attack path: **public app → RCE in a cluster-admin pod → read the `mongodb-uri` Secret and every other Secret → use the mounted admin token to schedule a pod on a node → reach the node/VM identities → the VM's compute.admin/storage.admin → read the public backup bucket and create new infrastructure.** A CNAPP ranks this single path above hundreds of isolated CVEs because exposure + privilege + data access line up.

## Controls that catch them
- **Preventative (CI):** Checkov + Trivy + gitleaks fail the build on any finding not on the documented skip list (`security/CHECKOV-SKIPS.md`). Remove a skip → pipeline blocks the deploy.
- **Preventative (cloud):** org-policy constraints (`storage.publicAccessPrevention`, `iam.disableServiceAccountKeyCreation`, `compute.vmExternalIpAccess`) in `terraform/security.tf`, gated behind `enable_org_policies` so you can enable one live and watch `terraform plan` refuse the weak resource.
- **Preventative (cluster):** hardened `prod` namespace (Pod Security "restricted"), Binary Authorization (signed images only).
- **Detective:** control-plane + data-access audit logging to a dedicated log bucket, and six log-based alerts (firewall opened to world, bucket made public, SSH accepted on the VM, owner/editor granted, cluster-admin binding created, kubectl exec into a pod).

## Attack simulation (for the demo, run deliberately and safely in the lab)
To show the detective controls firing, perform the benign equivalents of the first steps of the path and watch the alerts: open then close a wide firewall rule, add then remove a public bucket binding, and run `kubectl exec` into the app pod. Each should raise its corresponding alert within a minute. Do **not** run real exploit tooling; the point is to trigger the audit-log signatures the alerts watch for.
