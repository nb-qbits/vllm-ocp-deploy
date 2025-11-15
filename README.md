
**📘 Granite + vLLM One-Click Deployment for OpenShift**
This repository provides a fully automated one-click deploy script that installs:
* A GPU-backed vLLM inference server
* Running Granite models (or any VLLM-compatible Hugging Face or OCI model)
* On OpenShift using:
    * Deployment
    * Service
    * Route
    * Persistent model cache (PVC)
    * Automatic ORAS model pulling
    * GPU scheduling validation
    * Built-in health checks + curl test
The script collects minimal inputs and handles all required OpenShift objects automatically.

🚀 Features
✅ One-command deploy of vLLM on OpenShift ✅ Auto-pull Granite model via ORAS with secure registry auth ✅ Creates namespace, PVC, secrets, service, route, deployment ✅ Auto-detects GPU resources on the cluster ✅ Rejects deploy if insufficient GPU capacity ✅ Customizable max model length, namespace, route, model ✅ Validates pod readiness and prints real-time debugging checks ✅ Prints ready-to-use public inference URL ✅ Works on ROSA, ARO, CRC, and OpenShift 4.x clusters

📋 Requirements
* macOS / Linux
* oc CLI installed
* Logged into an OpenShift cluster: oc login ...
* 
* Red Hat registry credentials for pulling Granite model
* OpenShift nodes with NVIDIA GPUs and GPU Operator installed
* StorageClass capable of provisioning PersistentVolumeClaims

🧩 Script Overview
The script performs:
1. Namespace creation
2. GPU availability check (fail early if cluster lacks GPU)
3. Docker pull secret for Red Hat registry (registry.redhat.io)
4. PVC creation (persistent model cache)
5. Deployment including:
    * Init container running ORAS to pull model
    * vLLM container serving inference
    * GPU resource requests
6. Service creation (port 80 → 8000)
7. Route creation (edge TLS)
8. Pod readiness checks
9. Print final curl command

🔧 Installation
Clone the repository:
git clone https://github.com/<your-user>/granite-vllm-openshift-deploy.git
cd granite-vllm-openshift-deploy
Make the script executable:
chmod +x deploy-granite-vllm.sh

▶️ Usage
Run:
./deploy-granite.sh
You will be prompted for:
* Namespace
* Route name
* Model image reference
* Max model length
* GPU count
* Red Hat registry username

When deployment completes, you will get:
Your model is ready! 
Try:

curl -k -X POST https://granite8b-rhns.apps.cluster.example.com/v1/chat/completions \
...

🏗️ What the Script Creates
Component	Description
Namespace	Isolated environment for the deployment
PVC	Stores Granite model payload (safetensors)
Docker Secret	Used for ORAS auth to registry.redhat.io
Deployment	vLLM + initContainers
Service	ClusterIP service exposing port 80 → 8000
Route	Public HTTPS endpoint
GPU Scheduling	Requests NVIDIA GPUs
🖼️ Architecture Diagram
 User
   |
   |  HTTPS Request
   v
+---------------------------+
|        OpenShift Route    |
+---------------------------+
              |
              v
+---------------------------+
|      OpenShift Service    |
|      (port 80 → 8000)     |
+---------------------------+
              |
              v
+---------------------------------------------+
|               vLLM Pod                      |
|---------------------------------------------|
|  Init Container (ORAS → PVC)                |
|  Downloads Granite model via OCI registry   |
|---------------------------------------------|
|  Runtime Container (vLLM)                   |
|  Serves /v1/chat/completions on port 8000   |
|---------------------------------------------|
|  PVC Mounted @ /model                       |
|  NVIDIA GPU assigned                        |
+---------------------------------------------+

📤 Example Output
When ready:
=== vLLM Deployment Ready! ===

Route:
https://granite8b-rhns.apps.cluster.example.com

Test with curl:

curl -k -X POST https://granite8b-rhns.apps.cluster.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "granite-3-1-8b-instruct-quantized-w8a8",
        "messages": [{"role": "user", "content": "Hello!"}],
        "temperature": 0.1
      }'

🩺 Troubleshooting
Pod stuck in Pending
Check GPU availability:
oc describe pod <pod> -n <ns>
Init container failing
Check ORAS logs:
oc logs <pod> -c fetch-model -n <ns>
Service has no endpoints
Your deployment may not be Ready:
oc get deploy -n <ns>
Route returns empty reply
Check if the vLLM server is listening:
oc exec <pod> -n <ns> -- ss -tulpn | grep 8000

🧹 Cleanup
Delete all created resources in one command:
oc delete project <namespace>
