[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectId,
  [string]$Region = "us-central1",
  [string]$Zone = "us-central1-a",
  [string]$ClusterName = "demo-gke",
  [string]$NetworkName = "demo-vpc",
  [string]$SubnetName = "demo-subnet",
  [string]$SubnetCidr = "10.10.0.0/20",
  [string]$PodRangeName = "gke-pods",
  [string]$PodCidr = "10.20.0.0/16",
  [string]$SvcRangeName = "gke-services",
  [string]$SvcCidr = "10.30.0.0/20",
  [string]$NodeSaName = "gke-node-sa"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$NodeSa = "$NodeSaName@$ProjectId.iam.gserviceaccount.com"

Write-Host "== Set project/region ==" -ForegroundColor Cyan
gcloud config set project $ProjectId | Out-Host
gcloud config set compute/region $Region | Out-Host
gcloud config set compute/zone $Zone | Out-Host

Write-Host "== Enable required APIs ==" -ForegroundColor Cyan
gcloud services enable `
  compute.googleapis.com `
  container.googleapis.com `
  iam.googleapis.com `
  cloudresourcemanager.googleapis.com `
  artifactregistry.googleapis.com `
  cloudbuild.googleapis.com `
  logging.googleapis.com `
  monitoring.googleapis.com | Out-Host

Write-Host "== Create VPC + Subnet (alias IP ranges) ==" -ForegroundColor Cyan
gcloud compute networks create $NetworkName --subnet-mode=custom | Out-Host

gcloud compute networks subnets create $SubnetName `
  --network $NetworkName `
  --region $Region `
  --range $SubnetCidr `
  --secondary-range "$PodRangeName=$PodCidr,$SvcRangeName=$SvcCidr" | Out-Host

Write-Host "== Create node service account ==" -ForegroundColor Cyan
gcloud iam service-accounts create $NodeSaName --display-name "GKE Node SA ($ClusterName)" | Out-Host

Write-Host "== Bind baseline IAM roles to node SA ==" -ForegroundColor Cyan
gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$NodeSa" --role "roles/logging.logWriter" | Out-Host
gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$NodeSa" --role "roles/monitoring.metricWriter" | Out-Host
gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$NodeSa" --role "roles/monitoring.viewer" | Out-Host
gcloud projects add-iam-policy-binding $ProjectId --member "serviceAccount:$NodeSa" --role "roles/stackdriver.resourceMetadata.writer" | Out-Host

Write-Host "== Create regional GKE cluster ==" -ForegroundColor Cyan
gcloud container clusters create $ClusterName `
  --region $Region `
  --release-channel "regular" `
  --network $NetworkName `
  --subnetwork $SubnetName `
  --cluster-secondary-range-name $PodRangeName `
  --services-secondary-range-name $SvcRangeName `
  --workload-pool "$ProjectId.svc.id.goog" `
  --enable-ip-alias `
  --enable-shielded-nodes `
  --enable-autoupgrade `
  --enable-autorepair `
  --logging=SYSTEM,WORKLOAD `
  --monitoring=SYSTEM `
  --num-nodes 2 `
  --machine-type "e2-standard-4" `
  --service-account $NodeSa `
  --enable-autoscaling --min-nodes 2 --max-nodes 5 | Out-Host

Write-Host "== Get kubeconfig credentials ==" -ForegroundColor Cyan
gcloud container clusters get-credentials $ClusterName --region $Region | Out-Host

Write-Host "== Create namespace and deploy sample app ==" -ForegroundColor Cyan
kubectl create namespace demo 2>$null | Out-Null

$manifest = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:2.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: hello-lb
spec:
  type: LoadBalancer
  selector:
    app: hello
  ports:
  - name: http
    port: 80
    targetPort: 8080
'@

$manifest | kubectl -n demo apply -f - | Out-Host
kubectl -n demo rollout status deploy/hello | Out-Host

Write-Host "== Wait for external IP ==" -ForegroundColor Cyan
$externalIp = ""
for ($i=0; $i -lt 60; $i++) {
  $externalIp = (kubectl -n demo get svc hello-lb -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>$null)
  if ($externalIp) { break }
  Start-Sleep -Seconds 5
}
Write-Host "Service External IP: $externalIp" -ForegroundColor Green
if ($externalIp) { Write-Host "Test with: curl http://$externalIp/" -ForegroundColor Yellow }

Write-Host "== Add HPA ==" -ForegroundColor Cyan
kubectl -n demo autoscale deployment hello --cpu-percent=50 --min=2 --max=6 | Out-Host

Write-Host "== Show status ==" -ForegroundColor Cyan
kubectl -n demo get all | Out-Host
kubectl -n demo get hpa | Out-Host

Write-Host "Optional load test (separate terminal):" -ForegroundColor Yellow
Write-Host "kubectl -n demo run -it --rm loadgen --image=busybox:1.36 --restart=Never -- sh -c 'while true; do wget -q -O- http://hello-lb.demo.svc.cluster.local >/dev/null; done'"
