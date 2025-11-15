
---

# **vllm-ocp-deploy**

Deploy and expose **Granite vLLM** on **Red Hat OpenShift** using simple scripts.

---

# ⭐ Quickstart

## **Prerequisites**

* OpenShift cluster with GPU nodes.
* `oc` CLI installed.
* Logged in to your cluster:

  ```
  oc login ...
  ```
* Namespace created:

  ```
  oc new-project rhaiis-namespace
  ```

---

## **1. Deploy Granite vLLM**

```bash
chmod +x deploy-granite.sh
./deploy-granite.sh
```

---

## **2. Create Service + TLS Route**

```bash
chmod +x setup-granite-service.sh
./setup-granite-service.sh
```

This script:

* Creates a Service on port **8000**
* Creates a **TLS edge route**
* Validates pod → service → route connectivity
* Prints a ready-to-run curl command

---

## **3. Verify Pod Status**

```bash
oc get pods -n rhaiis-namespace
```

---

## **4. Test the Model via HTTPS Route**

```bash
curl -k "https://<your-route>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "granite-3-1-8b-instruct-quantized-w8a8",
        "messages":[{"role":"user","content":"Hello"}]
      }'
```

---

# 🛠️ Running vLLM Commands Inside the Container

Enter the running container:

```bash
oc exec -it -n rhaiis-namespace deploy/granite -- bash
```

or:

```bash
oc exec -it -n rhaiis-namespace deploy/granite -- sh
```

### Inside the container:

```
vllm --help
python -m vllm.scripts.benchmark_latency --model /model
python
from vllm import LLM, SamplingParams
```

---

# 🔗 Internal Cluster Testing

```bash
curl http://granite-service:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"granite-3-1-8b-instruct-quantized-w8a8","messages":[{"role":"user","content":"Hello"}]}'
```

---

# 🏗 Architecture Overview

```
+---------------------------------------------------------------+
|                        OpenShift Cluster                      |
|                                                               |
|   +------------------+       +----------------------+         |
|   | Granite Pod      |       | granite-service      |         |
|   | (vLLM Server)    |<----->| Port: 8000           |         |
|   |                  |       +----------------------+         |
|   |   python -m vllm |                                        |
|   +--------^---------+                                        |
|            |                                                  |
|            | (TLS Edge Route)                                 |
|   +--------v------------------------+                         |
|   | granite-route                   |                         |
|   | https://<your-route>           |                         |
|   +--------^------------------------+                         |
|            | (External HTTPS)                                |
+------------|--------------------------------------------------+
             |
       +-----v------+
       |  Client    |
       |  curl / python |
       +------------+
```

---

# 📁 examples/ folder (recommended)

You can optionally create an `examples/` folder with:

```
examples/
├── python-client.py
├── notebook.ipynb
└── README.md
```

### **Example: python-client.py**

```python
import openai

openai.api_key = "NONE"
openai.base_url = "https://<your-route>/v1/"

resp = openai.ChatCompletion.create(
    model="granite-3-1-8b-instruct-quantized-w8a8",
    messages=[{"role": "user", "content": "Hello from Python!"}]
)
print(resp["choices"][0]["message"]["content"])
```

### **Running the client:**

```
python examples/python-client.py
```

---

# 🚨 Troubleshooting

### **Pod stuck in Init / model not loaded**

Check model download logs:

```
oc logs -n rhaiis-namespace deploy/granite -c fetch-model
```

### **Pod cannot allocate GPU**

```
oc describe pod -n rhaiis-namespace <pod-name> | grep -i gpu
```

Ensure GPU operator & drivers are installed.

### **Route shows "Application is not available"**

Usually:

* Service not created
* Port incorrect
* Route not pointing to correct service

Re-run:

```
./setup-granite-service.sh
```

### **JSON decode error from vLLM**

Fix quotes:

```
-d '{"model":"granite-3-1-8b-instruct-quantized-w8a8","messages":[{"role":"user","content":"Hello"}]}'
```

### **Want logs from vLLM server?**

```
oc logs -n rhaiis-namespace deploy/granite -c granite -f
```

---

# 🐳 Local Testing (Optional, Podman)

If you want to test vLLM **locally**:

```
podman run --gpus all -p 8000:8000 \
  -v ./model:/model \
  registry.redhat.io/rhaiis/vllm-cuda-rhel9 \
  python -m vllm.entrypoints.openai.api_server \
    --model /model \
    --tensor-parallel-size 1
```

Test locally:

```
curl localhost:8000/v1/chat/completions \
 -H "Content-Type: application/json" \
 -d '{"model":"granite","messages":[{"role":"user","content":"Hello"}]}'
```

---

# 📚 Repository Contents

| File                       | Purpose                             |
| -------------------------- | ----------------------------------- |
| `deploy-granite.sh`        | Deploys Granite vLLM workload       |
| `setup-granite-service.sh` | Creates Service + TLS Route         |
| `README.md`                | Documentation                       |
| `examples/`                | Optional Python scripts & notebooks |


