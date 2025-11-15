#!/usr/bin/env bash
set -euo pipefail

### Helper: read with default
read_default() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local value
  read -r -p "$prompt [$default]: " value
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf -v "$var_name" '%s' "$value"
}

echo "=== Granite / vLLM one-click deploy for OpenShift ==="

# 0. Basic sanity check
if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: 'oc' CLI not found in PATH. Install it and log in to your cluster first."
  exit 1
fi

echo "Checking OpenShift login..."
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login ...' first."
  exit 1
fi

# 0.5 Preflight GPU usage check (very simple, best-effort)
echo
echo "=== Preflight: checking for existing GPU workloads (best effort) ==="
GPU_PODS=$(oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk '$2 != ""')

if [ -n "${GPU_PODS}" ]; then
  echo "WARNING: Found existing pods requesting GPUs:"
  echo "${GPU_PODS}"
  echo "If you later see 'Insufficient nvidia.com/gpu', scale down one of the above workloads first."
else
  echo "No existing GPU-requesting pods detected (or none with explicit GPU requests)."
fi


# 1. Collect inputs
echo
read_default NAMESPACE    "Namespace to deploy into"              "rhaiis-namespace"
read_default DEPLOY_NAME  "Deployment name"                       "granite"
read_default APP_NAME     "App label / Service name"              "${DEPLOY_NAME}"
read_default PVC_NAME     "PVC name"                              "model-cache"

read_default STORAGE_CLASS "StorageClass for PVC"                 "gp3-csi"
read_default PVC_SIZE      "PVC size"                             "20Gi"

read_default MODEL_ARTIFACT "Model artifact to pull (oras)" \
  "registry.redhat.io/rhelai1/granite-3-1-8b-instruct-quantized-w8a8:1.5"

read_default SERVED_MODEL_NAME "Served model name (vLLM 'model' value)" \
  "granite-3-1-8b-instruct-quantized-w8a8"

read_default MAX_MODEL_LEN  "vLLM max model length (tokens)"      "4096"
read_default GPU_RESOURCE   "Number of GPUs (nvidia.com/gpu)"     "1"
read_default ROUTE_NAME     "Route name"                          "${APP_NAME}"

echo
echo "=== Red Hat registry credentials (for registry.redhat.io) ==="
read -r -p "Red Hat registry username: " RH_USER
read -r -s -p "Red Hat registry password or token: " RH_PASS
echo

if [ -z "${RH_USER}" ] || [ -z "${RH_PASS}" ]; then
  echo "ERROR: Username and password/token are required."
  exit 1
fi

AUTH_B64=$(printf '%s' "${RH_USER}:${RH_PASS}" | base64 | tr -d '\n')

echo
echo "=== Summary of configuration ==="
cat <<EOF
Namespace:          ${NAMESPACE}
Deployment name:    ${DEPLOY_NAME}
App label:          ${APP_NAME}
PVC name:           ${PVC_NAME}
StorageClass:       ${STORAGE_CLASS}
PVC size:           ${PVC_SIZE}
Model artifact:     ${MODEL_ARTIFACT}
Served model name:  ${SERVED_MODEL_NAME}
Max model len:      ${MAX_MODEL_LEN}
GPUs:               ${GPU_RESOURCE}
Route name:         ${ROUTE_NAME}
Registry user:      ${RH_USER}
EOF
echo

# 2. Ensure namespace exists
if ! oc get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Creating namespace '${NAMESPACE}'..."
  oc create ns "${NAMESPACE}"
else
  echo "Namespace '${NAMESPACE}' already exists, continuing..."
fi

# 3. Create docker-secret with a minimal, container-safe config.json
echo "Creating temporary Docker auth config..."

TMP_DOCKER_CFG="$(mktemp)"

cat > "${TMP_DOCKER_CFG}" <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "${AUTH_B64}"
    }
  }
}
EOF

echo "Creating (or updating) docker-secret in namespace '${NAMESPACE}'..."
oc delete secret docker-secret -n "${NAMESPACE}" >/dev/null 2>&1 || true
oc create secret generic docker-secret \
  --from-file=config.json="${TMP_DOCKER_CFG}" \
  -n "${NAMESPACE}"

# 4. Create PVC
PVC_FILE="$(mktemp /tmp/${PVC_NAME}-XXXX-pvc.yaml)"
cat > "${PVC_FILE}" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF

echo "Applying PVC..."
oc apply -f "${PVC_FILE}"

# 5. Create Deployment (with initContainer pulling model)
DEPLOY_FILE="$(mktemp /tmp/${DEPLOY_NAME}-XXXX-deploy.yaml)"
cat > "${DEPLOY_FILE}" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      serviceAccountName: default

      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"

      imagePullSecrets:
        - name: docker-secret

      volumes:
        - name: model-volume
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: "2Gi"
        - name: oci-auth
          secret:
            secretName: docker-secret
            items:
              - key: config.json
                path: config.json

      initContainers:
        - name: fetch-model
          image: ghcr.io/oras-project/oras:v1.2.0
          env:
            - name: DOCKER_CONFIG
              value: /auth
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -ex
              if [ -z "\$(ls -A /model | grep -v '^lost+found$' || true)" ]; then
                echo "Pulling model..."
                cd /model
                oras pull ${MODEL_ARTIFACT}
              else
                echo "Model already present, skipping model pull"
              fi
          volumeMounts:
            - name: model-volume
              mountPath: /model
            - name: oci-auth
              mountPath: /auth
              readOnly: true

      containers:
        - name: ${APP_NAME}
          image: registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:a6645a8e8d7928dce59542c362caf11eca94bb1b427390e78f0f8a87912041cd
          imagePullPolicy: IfNotPresent
          env:
            - name: VLLM_SERVER_DEV_MODE
              value: "1"
          command:
            - python
            - -m
            - vllm.entrypoints.openai.api_server
          args:
            - --host=0.0.0.0
            - --port=8000
            - --model=/model
            - --served-model-name=${SERVED_MODEL_NAME}
            - --tensor-parallel-size=1
            - --max-model-len=${MAX_MODEL_LEN}
          resources:
            limits:
              cpu: "10"
              memory: 16Gi
              nvidia.com/gpu: "${GPU_RESOURCE}"
            requests:
              cpu: "2"
              memory: 6Gi
              nvidia.com/gpu: "${GPU_RESOURCE}"
          volumeMounts:
            - name: model-volume
              mountPath: /model
            - name: shm
              mountPath: /dev/shm
EOF

echo "Applying Deployment..."
oc apply -f "${DEPLOY_FILE}"

# 6. Create Service
SVC_FILE="$(mktemp /tmp/${APP_NAME}-XXXX-svc.yaml)"
cat > "${SVC_FILE}" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 8000
EOF

echo "Applying Service..."
oc apply -f "${SVC_FILE}"

# 7. Create Route
ROUTE_FILE="$(mktemp /tmp/${ROUTE_NAME}-XXXX-route.yaml)"
cat > "${ROUTE_FILE}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE_NAME}
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: ${APP_NAME}
  port:
    targetPort: http
  tls:
    termination: edge
EOF

echo "Applying Route..."
oc apply -f "${ROUTE_FILE}"

echo
echo "=== Waiting for pod to become Ready (Deployment Available) ==="
cat <<EOF

In another terminal, you can watch progress with:

  # Watch pods in this namespace
  oc get pods -n ${NAMESPACE} -w

  # Once a pod exists:
  POD=\$(oc get pod -l app=${APP_NAME} -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}')
  echo "Pod name: \$POD"

  # Describe pod (scheduling / PVC / GPU issues show in Events)
  oc describe pod \$POD -n ${NAMESPACE} | tail -n 40

  # Init container logs (model pull via oras)
  oc logs \$POD -c fetch-model -n ${NAMESPACE} --tail=40

  # Main container logs (vLLM)
  oc logs \$POD -c ${APP_NAME} -n ${NAMESPACE} --tail=40

EOF

if ! oc wait --for=condition=Available deploy/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=600s; then
  echo
  echo "WARNING: Deployment not Available yet."
  echo "Common causes: GPU unavailable, PVC Pending, model pull/auth failures, or vLLM startup errors."
  echo "Useful commands:"
  echo "  oc get pods -n ${NAMESPACE}"
  echo "  oc get pvc -n ${NAMESPACE}"
  echo "  POD=\$(oc get pod -l app=${APP_NAME} -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}')"
  echo "  oc describe pod \$POD -n ${NAMESPACE} | tail -n 40"
  echo "  oc logs \$POD -c fetch-model -n ${NAMESPACE} --tail=40"
fi

echo
echo "=== Resources in ${NAMESPACE} ==="
oc get pods,svc,route,pvc -n "${NAMESPACE}"

ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
echo
echo "=== Example curl command ==="
if [ -n "${ROUTE_HOST}" ]; then
  cat <<EOF
curl -k -X POST https://${ROUTE_HOST}/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "${SERVED_MODEL_NAME}",
    "messages": [{"role": "user", "content": "What is AI?"}],
    "temperature": 0.1
  }'
EOF
else
  echo "Route host not found yet. Get it with:"
  echo "  oc get route ${ROUTE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.host}'"
fi

echo
echo "Done."
