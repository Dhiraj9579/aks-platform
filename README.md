# AKS production-like demo

This repository contains Terraform for a private AKS environment, a small FastAPI service, and a GitHub Actions workflow to deploy it. It also installs Prometheus and Grafana and runs a daily report from Prometheus metrics.

**This is a demo, not a running environment.** No Azure resources have been created yet. Applying the Terraform will create billable resources, and deployment requires a machine with access to the private AKS API and private ACR.

## What is included

- A private AKS cluster, virtual network, private ACR and Key Vault, and Log Analytics workspace.
- A FastAPI app with health endpoints and Prometheus request, error, and latency metrics.
- Kubernetes deployment settings for non-root containers, resource limits, probes, a disruption budget, autoscaling, and network policy.
- A `kube-prometheus-stack` Helm release and an app dashboard.
- A daily CronJob that queries the last 24 hours of request, latency, error, CPU, and memory metrics.
- GitHub Actions checks for Terraform formatting/validation, Python tests, and Checkov; pushes to `main` can build and deploy the app.

## A few design trade-offs

- The AKS API, ACR, and Key Vault are private. This avoids exposing them publicly, but means local commands and the deployment runner need VNet connectivity.
- The workflow uses a self-hosted GitHub Actions runner in that network. It uses OIDC rather than a stored Azure client secret.
- Terraform expects a remote state backend for shared use, but this repository does not create one. Set up a private Azure Storage account/container separately and configure the backend before applying.
- The CI principal is assigned AKS RBAC Cluster Admin so the workflow can deploy the Kubernetes resources. That is broader than ideal; use a narrower role and validate all deployment operations before treating this as production-ready.
- The report is printed to the CronJob's logs. It is not exported to durable storage, so retain or export it separately if you need a long-term daily record.
- There is no public ingress for the app or Grafana. Use the cluster service internally or an approved private ingress.

This is a learning baseline, not a complete production landing zone. In particular, it does not configure backup/DR, alert routing, image signing and verification, or a managed lifecycle for the self-hosted runner.

## Before you start

You will need:

- An Azure subscription with permission to create the resources in `terraform\main.tf`, including role assignments.
- Azure CLI, Terraform 1.7 or later, kubectl, Helm 3, Docker, and Python 3.12.
- For deployment: a Linux self-hosted GitHub Actions runner with Docker, Azure CLI, kubectl, `kubelogin`, and Helm; give it network access to the private AKS API and ACR and the `aks-private` label.
- A GitHub OIDC federated credential for the workflow identity. No client secret is needed.

## Provision Azure resources

Log in and select the subscription:

```powershell
az login
az account set --subscription <subscription-id>
```

Set up the remote state backend before sharing this environment. Create the storage account and container separately, then add an `azurerm` backend configuration. Do not commit state files.

Copy `terraform\terraform.tfvars.example` to `terraform\terraform.tfvars`. Choose a globally unique `name_prefix`, a primary Azure region, and a different ACR replica region. Set `aks_admin_object_ids` to the Entra object IDs of people who need cluster-admin access. Set `ci_principal_object_id` to the deployment identity's **object ID** so Terraform can assign its ACR and AKS roles.

From the repository root, format, scan, and deploy:

Run the Terraform plan and apply from a host that can reach the private Key Vault endpoint and resolve its private DNS name. Terraform creates the disk-encryption key through the Key Vault data plane; a public-only shell cannot complete that step.

```powershell
terraform fmt -check -recursive
checkov -d terraform --framework terraform
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform apply tfplan
```

Review the Checkov output and keep a copy with your assignment evidence. The two skips in the recorded scan are documented on the ACR resource. Re-run the scan after changing Terraform; don't add skips just to get a clean result.

From a host connected to the VNet, get cluster credentials:

```powershell
az aks get-credentials --resource-group <resource-group> --name <cluster-name>
kubectl get nodes
```

The Terraform outputs include the resource group, AKS name, ACR details, Key Vault name, and private cluster FQDN. Keep credentials and Terraform state out of source control.

## Run the app locally

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r app\requirements-dev.txt
.venv\Scripts\python -m pytest app -q
docker build -t sample-web:local app
docker run --rm -p 8000:8000 sample-web:local
```

Try `http://localhost:8000`, `/docs`, or `/metrics`.

## Deploy and view monitoring

The GitHub Actions workflow handles the normal deployment path: it builds an image tagged with the commit SHA, pushes it to ACR, installs or updates the monitoring Helm release, then applies the Kubernetes manifests. For a manual deployment, first replace `__IMAGE__` in `k8s\app.yaml` with an image reference accessible to the cluster.

To install monitoring and apply the manifests from a VNet-connected host:

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --namespace monitoring --create-namespace `
  --values monitoring/values.yaml --wait --timeout 10m
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl apply -f monitoring/dashboard.yaml
```

The app is available inside the cluster at `http://sample-web.sample-app.svc.cluster.local`. To open Grafana locally without exposing it publicly:

```powershell
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

Open `http://localhost:3000`. To retrieve the chart-generated admin password:

```powershell
$encoded = kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
```

The **Sample App / Daily Performance** dashboard shows traffic, p95 latency, 5xx rate, CPU, and memory. The CronJob runs at 00:05 UTC. Check its most recent output with:

```powershell
kubectl -n sample-app get cronjobs
kubectl -n sample-app get jobs
kubectl -n sample-app logs job/<report-job-name>
```

## GitHub Actions setup

The workflow is in `.github\workflows\aks-production-platform.yml`. Pull requests run Terraform checks, Python tests, and Checkov. A push to `main` runs the deployment job after validation.

Add these GitHub repository variables:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` for OIDC.
- `ACR_NAME`, `AKS_RESOURCE_GROUP`, and `AKS_NAME` from Terraform outputs.

Set the federated credential subject to `repo:<owner>/<repo>:environment:production`. Also set `ci_principal_object_id` before applying Terraform, give the runner private network access, and protect the `main` branch and `production` environment with appropriate review rules.

## Checkov result

A previous local Checkov 3.4.5 run against AzureRM 4.81.0 was reported as **47 passed, 0 failed, 2 skipped**. The skips are `CKV_AZURE_164` (legacy ACR Content Trust) and `CKV_AZURE_166` (ACR quarantine). The result has not been independently rerun, and its report is not stored in the repository. Run Checkov again and save the output if you need current evidence.

## Cost and cleanup

The AKS node pools, Premium geo-replicated ACR, Premium Key Vault/HSM key, Log Analytics, and private endpoints all incur charges. When finished, review any retained state or data, then run `terraform -chdir=terraform destroy` from a configured working directory. Key Vault soft-delete and purge protection mean deleted vault names and keys remain unavailable during the retention period.
