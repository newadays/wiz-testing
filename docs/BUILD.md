# Build & deploy runbook

Prereqs: a CloudLabs GCP project, `gcloud`, `terraform`, `kubectl`, `docker`, and a GitHub repo.

## 0. One-time bootstrap
```bash
gcloud auth login && gcloud config set project PROJECT_ID
gcloud storage buckets create gs://PROJECT_ID-tfstate --location us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://PROJECT_ID-tfstate --versioning
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill project, operator_cidr, github_repo, alert_email
```

## 1. Infrastructure (locally the first time, or push to let the pipeline do it)
```bash
cd terraform
terraform init -backend-config="bucket=PROJECT_ID-tfstate"
terraform plan  -out tfplan            # read it
terraform apply tfplan
terraform output                       # mongo IPs, bucket URL, registry, WIF provider, CI SAs
```

## 2. Wire the pipelines (GitHub repo → Settings → Secrets and variables → Actions → Variables)
Set repo **variables** from the Terraform outputs: `GCP_PROJECT`, `TF_STATE_BUCKET`, `WIF_PROVIDER`, `CI_IAC_SA`, `CI_APP_SA`, `OPERATOR_CIDR`, `ALERT_EMAIL`, `CANDIDATE_NAME`. Add a protected `production` environment with yourself as required reviewer.

## 3. App image + deploy (the `app.yml` pipeline does all of this on push to main)
```bash
# manual equivalent, for the first run:
gcloud auth configure-docker us-central1-docker.pkg.dev
docker build -t us-central1-docker.pkg.dev/PROJECT_ID/apps/tasky:v1 app
docker run --rm us-central1-docker.pkg.dev/PROJECT_ID/apps/tasky:v1 cat /app/wizexercise.txt   # proves the file is in the image
docker push us-central1-docker.pkg.dev/PROJECT_ID/apps/tasky:v1
gcloud container clusters get-credentials wiz-gke --zone us-central1-a
kubectl apply -f k8s/namespace.yaml
gcloud secrets versions access latest --secret mongodb-uri > uri.txt
kubectl -n tasky create secret generic mongodb-uri --from-file=uri=uri.txt && rm uri.txt
cd k8s && sed -i "s#PROJECT_ID#PROJECT_ID#g" *.yaml && kubectl apply -k .
kubectl -n tasky rollout status deployment/tasky
```

## 4. Validate
```bash
kubectl -n tasky get pods,svc,ingress
kubectl -n tasky exec deploy/tasky -- cat /app/wizexercise.txt        # file in the RUNNING container
IP=$(kubectl -n tasky get ingress tasky -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$IP/ ; curl http://$IP/api/todos                          # app works, data is in Mongo
gsutil ls gs://PROJECT_ID-gbenga-mongo-backups/backups/               # daily backup landed
```

## Teardown
```bash
# or trigger the iac pipeline with destroy=true
cd terraform && terraform destroy
```
