# Demo script (45 min: ~20 slides, ~20 live, ~5 Q&A buffer)

1. **Overview + architecture** (slides 1–3). One diagram, the two tiers, the data flow to backups.
2. **How it was built** (slide 4). Terraform + two pipelines, OIDC (no keys), state in GCS.
3. **Live: it works.**
   - `kubectl -n tasky get pods,svc,ingress`
   - Open `http://<ingress-ip>/`, add a todo.
   - Prove data is in Mongo: `curl http://<ingress-ip>/api/todos`, or SSH the VM and `mongo todo --eval 'db.todos.find()'` with auth.
4. **Live: wizexercise.txt in the running container.**
   `kubectl -n tasky exec deploy/tasky -- cat /app/wizexercise.txt`
5. **Live: the backups.** `gsutil ls` the bucket, then show it's public from an unauthenticated `curl`.
6. **Weak configs + consequences** (slide 6 + `SECURITY-FINDINGS.md`). Walk the toxic-combination path.
7. **Live: the controls.**
   - CI: open a PR removing a skip → Checkov blocks.
   - Cloud: `enable_org_policies = true`, `terraform plan` → public bucket binding refused.
   - Detective: trigger one benign signature (open/close a firewall rule) → alert fires.
8. **How Wiz would collapse this** (closing). One graph query vs. six separate tools; runtime context on which CVEs are actually loaded.

**Challenges to mention** (slide 5): private cluster + CI reachability (solved with the Connect gateway, not by opening the API to the internet); getting `wizexercise.txt` into the image layer (COPY from build context, not a runtime mount) and proving it; keeping the public bucket binding from being refused by default public-access-prevention.
