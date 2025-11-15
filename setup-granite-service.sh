#!/usr/bin/env sh
set -e

########################################
# CONFIG
########################################
NAMESPACE="rhaiis-namespace"
APP_LABEL="granite"
SERVICE_NAME="granite-service"
ROUTE_NAME="granite-route"
SERVICE_PORT=8000
MODEL_NAME="granite-3-1-8b-instruct-quantized-w8a8"
TLS_TERMINATION="edge"                 # edge / passthrough / reencrypt
INSECURE_POLICY="Redirect"             # Redirect / Allow / None
########################################

echo "👉 Namespace: ${NAMESPACE}"
echo "👉 App label: ${APP_LABEL}"
echo "👉 Service:   ${SERVICE_NAME}"
echo "👉 Route:     ${ROUTE_NAME}"
echo

########################################
# 0. Basic sanity checks
########################################

if ! command -v oc >/dev/null 2>&1; then
  echo "❌ 'oc' command not found. Install OpenShift CLI and login first."
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "❌ Not logged into a cluster. Run 'oc login' first."
  exit 1
fi

echo "✅ 'oc' CLI present and logged in."
echo

########################################
# 1. Switch project & check pod
########################################

echo "➡ Switching to project ${NAMESPACE}..."
oc project "${NAMESPACE}" >/dev/null

echo "➡ Checking for pods with label app=${APP_LABEL}..."
POD_NAME=$(oc get pods -n "${NAMESPACE}" -l "app=${APP_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${POD_NAME}" ]; then
  echo "❌ No pod found with label app=${APP_LABEL} in namespace ${NAMESPACE}."
  echo "   Make sure your Deployment is applied and running."
  exit 1
fi

POD_STATUS=$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
echo "   Found pod: ${POD_NAME} (status: ${POD_STATUS})"

if [ "${POD_STATUS}" != "Running" ]; then
  echo "❌ Pod is not Running. Check with:"
  echo "   oc describe pod ${POD_NAME} -n ${NAMESPACE}"
  echo "   oc logs ${POD_NAME} -n ${NAMESPACE}"
  exit 1
fi

echo "✅ Pod is running."
echo

########################################
# 2. Delete old Service & Route if they exist
########################################

echo "➡ Cleaning up any existing Service/Route..."

if oc get svc "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "   Deleting existing Service ${SERVICE_NAME}..."
  oc delete svc "${SERVICE_NAME}" -n "${NAMESPACE}"
fi

if oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "   Deleting existing Route ${ROUTE_NAME}..."
  oc delete route "${ROUTE_NAME}" -n "${NAMESPACE}"
fi

echo "✅ Cleanup done."
echo

########################################
# 3. Create Service
########################################

echo "➡ Creating Service ${SERVICE_NAME}..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_LABEL}
  ports:
    - name: http
      port: ${SERVICE_PORT}
      targetPort: ${SERVICE_PORT}
      protocol: TCP
EOF

echo "✅ Service created/applied."
echo

########################################
# 4. Verify Service endpoints
########################################

echo "➡ Checking Service endpoints..."
sleep 3

ENDPOINT_IPS=$(oc get endpoints "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || true)

if [ -z "${ENDPOINT_IPS}" ]; then
  echo "❌ Service ${SERVICE_NAME} has NO endpoints."
  echo "   Likely the Service selector does not match pod labels,"
  echo "   or the pod is not Ready."
  echo
  echo "   Debug with:"
  echo "   oc get endpoints ${SERVICE_NAME} -n ${NAMESPACE} -o yaml"
  echo "   oc get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.metadata.labels}{\"\\n\"}'"
  exit 1
fi

echo "✅ Service has endpoints: ${ENDPOINT_IPS}"
echo

########################################
# 5. Create TLS-enabled Route
########################################

echo "➡ Creating TLS Route ${ROUTE_NAME} pointing to Service ${SERVICE_NAME}..."

# Use 'oc create route edge' so we get spec.tls populated
oc create route "${TLS_TERMINATION}" "${ROUTE_NAME}" \
  --service="${SERVICE_NAME}" \
  --port="http" \
  --insecure-policy="${INSECURE_POLICY}" \
  -n "${NAMESPACE}"

ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}')

if [ -z "${ROUTE_HOST}" ]; then
  echo "❌ Failed to determine route host."
  echo "   Check with: oc get route ${ROUTE_NAME} -n ${NAMESPACE} -o yaml"
  exit 1
fi

echo "✅ Route created: https://${ROUTE_HOST}"
echo

########################################
# 6. Optional in-cluster Service test
########################################

echo "➡ Testing vLLM via Service from inside pod ${POD_NAME}..."

oc exec -n "${NAMESPACE}" "${POD_NAME}" -- \
  curl -sS "http://${SERVICE_NAME}:${SERVICE_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
          \"model\": \"${MODEL_NAME}\",
          \"messages\": [
            {\"role\": \"user\", \"content\": \"Hello via Service\"}
          ]
        }" \
    >/dev/null \
  && echo "✅ In-cluster Service test OK." \
  || echo "⚠ In-cluster Service test FAILED (check Service DNS/ports)."

echo

########################################
# 7. External HTTPS Route health check
########################################

echo "➡ Performing external HTTPS health check via Route (using curl -k)..."

HTTP_CODE=$(curl -k -sS -o /dev/null -w "%{http_code}" \
  "https://${ROUTE_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
          {\"role\": \"user\", \"content\": \"Health check from script\"}
        ]
      }" || echo "000")

if [ "${HTTP_CODE}" = "200" ]; then
  echo "✅ Route health check succeeded (HTTP 200)."
else
  echo "⚠ Route health check did NOT return 200 (got: ${HTTP_CODE})."
  echo "   If you still see 'Application is not available', check router logs and Route details:"
  echo "   oc describe route ${ROUTE_NAME} -n ${NAMESPACE}"
fi

echo
echo "🎉 Done. Service + TLS Route are set up."

echo
echo "👉 Your vLLM endpoint (HTTPS Route):"
echo "   https://${ROUTE_HOST}/v1/chat/completions"
echo
echo "➡ Example curl you can run yourself:"
cat <<EOF
curl -k "https://${ROUTE_HOST}/v1/chat/completions" \\
  -H "Content-Type: application/json" \\
  -d "{
        \\"model\\": \\"${MODEL_NAME}\\",
        \\"messages\\": [
          {\\"role\\": \\"user\\", \\"content\\": \\"Hello from OpenShift vLLM via TLS Route!\\"}
        ]
      }"
EOF

echo
echo "✅ Script finished."
