#!/usr/bin/with-contenv bashio
set -e

CONFIG_PATH=/data/options.json

SERVER=$(jq -r '.server' "$CONFIG_PATH")
EMAIL=$(jq -r '.email' "$CONFIG_PATH")
DAYS=$(jq -r '.days' "$CONFIG_PATH")
DOMAIN=$(jq -r '.domain' "$CONFIG_PATH")
EXTRA_DOMAINS=$(jq -r '.extra_domains[]?' "$CONFIG_PATH" 2>/dev/null | xargs || true)
NGINX_ADDON=$(jq -r '.nginx_addon_slug' "$CONFIG_PATH")
INSECURE=$(jq -r '.use_insecure' "$CONFIG_PATH")
FORCE=$(jq -r '.use_force' "$CONFIG_PATH")
FORCE_ISSUE=$(jq -r '.force_issue' "$CONFIG_PATH")

# --- Validation ---
if [ -z "$SERVER" ] || [ "$SERVER" = "null" ]; then
  echo "[ERROR] ACME server URL not set!"
  exit 1
fi

if [ -z "$EMAIL" ] || [ "$EMAIL" = "null" ]; then
  echo "[ERROR] Account email not set!"
  exit 1
fi

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
  echo "[ERROR] Primary domain not set!"
  exit 1
fi

# --- Paths for persistent acme.sh data ---
ACME_CONFIG="/data/acme_conf"
ACME_CERT="/data/acme_certs"
SSL_DIR="/ssl/acme"
mkdir -p "$ACME_CONFIG" "$ACME_CERT" "$SSL_DIR"

# --- Define helper function for acme.sh commands ---

acme() {
  /root/.acme.sh/acme.sh --config-home "$ACME_CONFIG" --cert-home "$ACME_CERT" "$@"
}

# Set the insecure flag if INSECURE is true
if [ "$INSECURE" = "true" ]; then
  echo "[WARN] Skipping TLS verification for ACME server"
  INSECURE_FLAG="--insecure"
else
  INSECURE_FLAG=""
fi

# Set the force flag if FORCE is true
if [ "$FORCE" = "true" ]; then
  echo "[INFO] Force renewal enabled (--force)"
  FORCE_FLAG="--force"
else
  FORCE_FLAG=""
fi

# --- Build domain arguments ---
DOMAIN_ARGS=(-d "$DOMAIN")
for d in $EXTRA_DOMAINS; do
  DOMAIN_ARGS+=(-d "$d")
done

# --- Function: stop NGINX add-on if configured ---
stop_nginx() {
  echo "[TDB] Nginx mock stop"
  # TBD Need bashio
  #if [ -n "$NGINX_ADDON" ] && [ "$NGINX_ADDON" != "null" ] && [ "$NGINX_ADDON" != "" ]; then
  #  echo "[INFO] Stopping NGINX add-on: $NGINX_ADDON"
  #  curl -s -X POST \
  #    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  #    -H "Content-Type: application/json" \
  #    "http://supervisor/addons/$NGINX_ADDON/stop" ||
  #    echo "[WARN] Failed to stop NGINX add-on"
  #fi
}

# --- Function: start NGINX add-on if configured ---
start_nginx() {
  echo "[TDB] Nginx mock start"
  # TBD Need bashio
  #if [ -n "$NGINX_ADDON" ] && [ "$NGINX_ADDON" != "null" ] && [ "$NGINX_ADDON" != "" ]; then
  #  echo "[INFO] Starting NGINX add-on: $NGINX_ADDON"
  #  curl -s -X POST \
  #    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  #    -H "Content-Type: application/json" \
  #    "http://supervisor/addons/$NGINX_ADDON/start" ||
  #    echo "[WARN] Failed to start NGINX add-on"
  #fi
}

# --- Function: issue new certificate ---
issue_cert() {
  echo "[INFO] Issuing new certificate for $DOMAIN"
  acme --issue --server "$SERVER" --email "$EMAIL" --days "$DAYS" --accountemail "$EMAIL" --standalone $INSECURE_FLAG "${DOMAIN_ARGS[@]}"
}

# --- Main logic ---
stop_nginx

if [ "$FORCE_ISSUE" = "true" ]; then
  echo "[INFO] Force new issue enabled — skipping renewal"
  issue_cert
else
  echo "[INFO] Attempting renewal for $DOMAIN"
  if acme --renew -d "$DOMAIN" --server "$SERVER" --days "$DAYS" $INSECURE_FLAG $FORCE_FLAG; then
    echo "[INFO] Renewal succeeded for $DOMAIN"
  else
    echo "[WARN] Renewal failed or no existing certificate — issuing new one"
    issue_cert
  fi
fi

# --- Install certs to /ssl/acme for other add-ons ---
echo "[INFO] Installing certificates to $SSL_DIR"
acme --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN.key" --fullchain-file "$SSL_DIR/$DOMAIN.cer"

start_nginx

echo "[INFO] Certificate issue/renew completed successfully."
