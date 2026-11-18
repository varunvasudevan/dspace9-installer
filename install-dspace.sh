#!/usr/bin/env bash
# =============================================================================
#  DSpace 9.x — Full Installation Script (Backend + Frontend)
#  Target OS : Ubuntu 22.04 / 24.04 LTS (Debian-family)
#  Stack     : OpenJDK 21, PostgreSQL (distro), Solr 9.x, Tomcat 10.1,
#              Maven, Ant, Node.js 22 LTS, PM2, Nginx (optional) + Certbot
#
#  Usage:
#    sudo ./install-dspace.sh                 # run every step
#    sudo ./install-dspace.sh frontend nginx  # re-run only selected steps
#    sudo ./install-dspace.sh --list          # show step names
#
#  Override any setting below with environment variables or by creating
#  ./dspace-install.conf (sourced automatically), e.g.:
#    DOMAIN=repo.example.org ENABLE_SSL=yes SSL_EMAIL=me@example.org \
#    ADMIN_EMAIL=admin@example.org sudo -E ./install-dspace.sh
# =============================================================================
set -Eeuo pipefail

# ----------------------------- CONFIGURATION ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/dspace-install.conf" ]] && source "${SCRIPT_DIR}/dspace-install.conf"

# Versions (check https://github.com/DSpace/DSpace/releases before running)
DSPACE_VERSION="${DSPACE_VERSION:-9.2}"
SOLR_VERSION="${SOLR_VERSION:-9.10.1}"
TOMCAT_VERSION="${TOMCAT_VERSION:-10.1.55}"
NODE_MAJOR="${NODE_MAJOR:-22}"
JAVA_PKG="${JAVA_PKG:-openjdk-21-jdk-headless}"

# System user / paths
DSPACE_USER="${DSPACE_USER:-dspace}"
DSPACE_DIR="${DSPACE_DIR:-/dspace}"                    # [dspace] install dir
SRC_DIR="${SRC_DIR:-/opt/dspace-src}"                  # source + build dir
UI_DIR="${UI_DIR:-/opt/dspace-ui}"                     # deployed Angular UI
TOMCAT_DIR="${TOMCAT_DIR:-/opt/tomcat}"
SOLR_DATA_DIR="${SOLR_DATA_DIR:-/var/solr}"

# Site
DSPACE_NAME="${DSPACE_NAME:-DSpace Repository}"
DOMAIN="${DOMAIN:-$(hostname -I 2>/dev/null | awk '{print $1}')}"  # FQDN or IP
ENABLE_NGINX="${ENABLE_NGINX:-yes}"     # yes = reverse proxy on :80/:443
ENABLE_SSL="${ENABLE_SSL:-no}"          # yes = Let's Encrypt (needs real DNS)
SSL_EMAIL="${SSL_EMAIL:-}"

# Database
DB_NAME="${DB_NAME:-dspace}"
DB_USER="${DB_USER:-dspace}"
DB_PASS="${DB_PASS:-$(openssl rand -hex 16)}"           # alphanumeric only!

# Initial administrator
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.org}"
ADMIN_FIRST="${ADMIN_FIRST:-Repository}"
ADMIN_LAST="${ADMIN_LAST:-Admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)}"
ADMIN_LANG="${ADMIN_LANG:-en}"

# Tuning
TOMCAT_XMX="${TOMCAT_XMX:-2048m}"
SOLR_HEAP="${SOLR_HEAP:-1g}"
PM2_INSTANCES="${PM2_INSTANCES:-2}"
UI_BUILD_HEAP_MB="${UI_BUILD_HEAP_MB:-4096}"

# Download mirrors (archive.apache.org keeps every old release)
SOLR_URL="https://archive.apache.org/dist/solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz"
TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
BACKEND_URL="https://github.com/DSpace/DSpace/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz"
FRONTEND_URL="https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz"

LOG_FILE="/var/log/dspace-install.log"
CRED_FILE="/root/dspace-install-credentials.txt"
STATE_DIR="/var/lib/dspace-install"      # step markers so re-runs are safe

# ------------------------------ DERIVED URLS ---------------------------------
if [[ "${ENABLE_NGINX}" == "yes" ]]; then
  if [[ "${ENABLE_SSL}" == "yes" ]]; then SCHEME="https"; PUB_PORT=443; else SCHEME="http"; PUB_PORT=80; fi
  UI_URL="${SCHEME}://${DOMAIN}"
  SERVER_URL="${SCHEME}://${DOMAIN}/server"
  UI_BIND="127.0.0.1"
  REST_PORT="${PUB_PORT}"
else
  SCHEME="http"
  UI_URL="http://${DOMAIN}:4000"
  SERVER_URL="http://${DOMAIN}:8080/server"
  UI_BIND="0.0.0.0"
  REST_PORT=8080
fi
REST_SSL=$([[ "${SCHEME}" == "https" ]] && echo true || echo false)

# ------------------------------- HELPERS -------------------------------------
c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'; c_off='\033[0m'
log()  { echo -e "${c_green}[$(date +%T)] $*${c_off}"; }
warn() { echo -e "${c_yellow}[$(date +%T)] WARNING: $*${c_off}"; }
die()  { echo -e "${c_red}[$(date +%T)] ERROR: $*${c_off}"; exit 1; }
hdr()  { echo -e "\n${c_blue}==================== $* ====================${c_off}"; }
trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}  (see ${LOG_FILE})"' ERR

as_dspace() { sudo -u "${DSPACE_USER}" -H bash -lc "$*"; }
done_mark() { touch "${STATE_DIR}/$1.done"; }
is_done()   { [[ -f "${STATE_DIR}/$1.done" ]]; }

download() {  # download <url> <dest>
  local url="$1" dest="$2"
  if [[ -s "${dest}" ]]; then log "Already downloaded: ${dest}"; return; fi
  log "Downloading ${url}"
  wget -q --show-progress -O "${dest}.part" "${url}" && mv "${dest}.part" "${dest}"
}

wait_for_http() {  # wait_for_http <url> <seconds>
  local url="$1" t="${2:-180}" i=0
  until curl -fsS -o /dev/null "${url}"; do
    (( i += 5 )); (( i > t )) && { warn "Timed out waiting for ${url}"; return 1; }
    sleep 5
  done
  log "Reachable: ${url}"
}

# =============================== STEPS =======================================

step_preflight() {
  hdr "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
  . /etc/os-release
  [[ "${ID}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] || die "Ubuntu/Debian required (found ${ID})."
  log "OS: ${PRETTY_NAME}"
  local mem_gb; mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  (( mem_gb < 4 )) && warn "Only ${mem_gb} GB RAM. 4 GB+ recommended (8 GB for the Angular build). Consider adding swap."
  local free_gb; free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  (( free_gb < 15 )) && warn "Only ${free_gb} GB free on /. 15 GB+ recommended."
  [[ "${DB_PASS}" =~ ^[A-Za-z0-9]+$ ]] || die "DB_PASS must be alphanumeric."
  [[ "${ENABLE_SSL}" == "yes" && -z "${SSL_EMAIL}" ]] && die "ENABLE_SSL=yes requires SSL_EMAIL."
  log "UI URL     : ${UI_URL}"
  log "Server URL : ${SERVER_URL}"
}

step_packages() {
  hdr "System packages, Java, Maven, Ant, PostgreSQL"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${JAVA_PKG}" maven ant git wget curl unzip tar lsof gnupg ca-certificates \
    build-essential postgresql postgresql-contrib openssl cron
  # Persist JAVA_HOME for every tool
  local jhome; jhome="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  echo "export JAVA_HOME=${jhome}" > /etc/profile.d/java-home.sh
  export JAVA_HOME="${jhome}"
  java -version 2>&1 | head -1
  mvn -v | head -1
  ant -version
}

step_node() {
  hdr "Node.js ${NODE_MAJOR} LTS + PM2"
  if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" != "${NODE_MAJOR}" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
  npm install -g pm2
  log "Node $(node -v), npm $(npm -v), PM2 $(pm2 -v)"
}

step_user() {
  hdr "System user '${DSPACE_USER}' and directories"
  id "${DSPACE_USER}" &>/dev/null || useradd -m -s /bin/bash "${DSPACE_USER}"
  mkdir -p "${DSPACE_DIR}" "${SRC_DIR}" "${UI_DIR}"
  chown -R "${DSPACE_USER}:${DSPACE_USER}" "${DSPACE_DIR}" "${SRC_DIR}" "${UI_DIR}"
}

step_database() {
  hdr "PostgreSQL database '${DB_NAME}'"
  systemctl enable --now postgresql
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL
  if ! sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "${DB_NAME}"; then
    sudo -u postgres createdb --owner="${DB_USER}" --encoding=UNICODE --template=template0 "${DB_NAME}"
  fi
  sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
  log "Database ready (password stored in ${CRED_FILE})."
}

step_solr() {
  hdr "Apache Solr ${SOLR_VERSION}"
  if [[ ! -d "/opt/solr-${SOLR_VERSION}" ]]; then
    local tgz="/tmp/solr-${SOLR_VERSION}.tgz"
    download "${SOLR_URL}" "${tgz}"
    tar xzf "${tgz}" -C /tmp "solr-${SOLR_VERSION}/bin/install_solr_service.sh" --strip-components=2
    systemctl stop solr 2>/dev/null || true
    bash /tmp/install_solr_service.sh "${tgz}" -i /opt -d "${SOLR_DATA_DIR}" -u solr -s solr -p 8983 -n -f
  fi
  local inc=/etc/default/solr.in.sh
  # DSpace cores load extra jars via <lib> -> required on Solr >= 9.8
  grep -q 'solr.config.lib.enabled' "${inc}" || \
    echo 'SOLR_OPTS="$SOLR_OPTS -Dsolr.config.lib.enabled=true"' >> "${inc}"
  sed -i "s|^#\?SOLR_HEAP=.*|SOLR_HEAP=\"${SOLR_HEAP}\"|" "${inc}"
  grep -q '^SOLR_JETTY_HOST=' "${inc}" || echo 'SOLR_JETTY_HOST="127.0.0.1"' >> "${inc}"
  # Raise limits Solr complains about
  cat > /etc/security/limits.d/solr.conf <<EOF
solr soft nofile 65000
solr hard nofile 65000
solr soft nproc  65000
solr hard nproc  65000
EOF
  systemctl daemon-reload
  systemctl enable solr
  systemctl restart solr
  wait_for_http "http://127.0.0.1:8983/solr/" 120
}

step_tomcat() {
  hdr "Apache Tomcat ${TOMCAT_VERSION}"
  if [[ ! -f "${TOMCAT_DIR}/bin/catalina.sh" ]]; then
    local tgz="/tmp/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    download "${TOMCAT_URL}" "${tgz}"
    mkdir -p "${TOMCAT_DIR}"
    tar xzf "${tgz}" -C "${TOMCAT_DIR}" --strip-components=1
    rm -rf "${TOMCAT_DIR}/webapps/"{docs,examples,host-manager,manager,ROOT}
  fi
  # Behind Nginx: listen on localhost only
  if [[ "${ENABLE_NGINX}" == "yes" ]] && ! grep -q 'address="127.0.0.1"' "${TOMCAT_DIR}/conf/server.xml"; then
    sed -i 's|<Connector port="8080" protocol="HTTP/1.1"|<Connector port="8080" address="127.0.0.1" protocol="HTTP/1.1"|' \
      "${TOMCAT_DIR}/conf/server.xml"
  fi
  chown -R "${DSPACE_USER}:${DSPACE_USER}" "${TOMCAT_DIR}"
  # shellcheck disable=SC1091
  source /etc/profile.d/java-home.sh
  cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat ${TOMCAT_VERSION} (DSpace backend)
After=network.target postgresql.service solr.service
Wants=postgresql.service solr.service

[Service]
Type=forking
User=${DSPACE_USER}
Group=${DSPACE_USER}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="CATALINA_HOME=${TOMCAT_DIR}"
Environment="CATALINA_BASE=${TOMCAT_DIR}"
Environment="CATALINA_PID=${TOMCAT_DIR}/temp/tomcat.pid"
Environment="JAVA_OPTS=-Xms512m -Xmx${TOMCAT_XMX} -Dfile.encoding=UTF-8 -Djava.awt.headless=true"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
SuccessExitStatus=143
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable tomcat
}

step_backend() {
  hdr "DSpace ${DSPACE_VERSION} backend (build + install)"
  local src="${SRC_DIR}/DSpace-dspace-${DSPACE_VERSION}"
  if [[ ! -d "${src}" ]]; then
    download "${BACKEND_URL}" "/tmp/dspace-backend-${DSPACE_VERSION}.tar.gz"
    tar xzf "/tmp/dspace-backend-${DSPACE_VERSION}.tar.gz" -C "${SRC_DIR}"
    chown -R "${DSPACE_USER}:${DSPACE_USER}" "${SRC_DIR}"
  fi

  # local.cfg — overrides dspace.cfg
  cat > "${src}/dspace/config/local.cfg" <<EOF
# Generated by install-dspace.sh on $(date)
dspace.dir = ${DSPACE_DIR}
dspace.server.url = ${SERVER_URL}
dspace.ui.url = ${UI_URL}
dspace.name = ${DSPACE_NAME}

solr.server = http://localhost:8983/solr

db.url = jdbc:postgresql://localhost:5432/${DB_NAME}
db.driver = org.postgresql.Driver
db.username = ${DB_USER}
db.password = ${DB_PASS}
db.schema = public

# Allow the UI origin to call the REST API
rest.cors.allowed-origins = \${dspace.ui.url}

# Behind a reverse proxy
useProxies = true

mail.server = localhost
mail.from.address = ${ADMIN_EMAIL}
mail.admin = ${ADMIN_EMAIL}
feedback.recipient = ${ADMIN_EMAIL}
EOF
  chown "${DSPACE_USER}:${DSPACE_USER}" "${src}/dspace/config/local.cfg"
  chmod 640 "${src}/dspace/config/local.cfg"

  log "Maven build (10-20 min on first run)..."
  as_dspace "cd '${src}' && MAVEN_OPTS='-Xmx2g' mvn -B package -DskipTests"

  systemctl stop tomcat 2>/dev/null || true
  local installer="${src}/dspace/target/dspace-installer"
  if [[ -f "${DSPACE_DIR}/config/dspace.cfg" ]]; then
    log "Existing install found -> ant update"
    as_dspace "cd '${installer}' && ant update"
  else
    log "ant fresh_install"
    as_dspace "cd '${installer}' && ant fresh_install"
  fi

  log "Database migration"
  as_dspace "'${DSPACE_DIR}/bin/dspace' database migrate"
  as_dspace "'${DSPACE_DIR}/bin/dspace' database info" | tail -n 5 || true
}

step_solr_cores() {
  hdr "Install DSpace Solr cores"
  local data="${SOLR_DATA_DIR}/data"
  systemctl stop solr
  for core in "${DSPACE_DIR}"/solr/*; do
    local name; name=$(basename "${core}")
    if [[ -d "${data}/${name}" ]]; then
      log "Refreshing conf for core '${name}'"
      rm -rf "${data:?}/${name}/conf"
      cp -R "${core}/conf" "${data}/${name}/"
    else
      log "Adding core '${name}'"
      cp -R "${core}" "${data}/"
    fi
  done
  chown -R solr:solr "${data}"
  systemctl start solr
  wait_for_http "http://127.0.0.1:8983/solr/search/admin/ping" 120 || \
    warn "Solr 'search' core not responding yet — check: journalctl -u solr"
}

step_deploy_backend() {
  hdr "Deploy backend webapp to Tomcat (/server)"
  mkdir -p "${TOMCAT_DIR}/conf/Catalina/localhost"
  cat > "${TOMCAT_DIR}/conf/Catalina/localhost/server.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Context docBase="${DSPACE_DIR}/webapps/server" reloadable="false" />
EOF
  chown -R "${DSPACE_USER}:${DSPACE_USER}" "${TOMCAT_DIR}/conf"
  systemctl restart tomcat
  log "Waiting for REST API (first boot can take 1-3 min)..."
  wait_for_http "http://127.0.0.1:8080/server/api" 300 || \
    warn "Backend not up yet — check ${TOMCAT_DIR}/logs/catalina.out and ${DSPACE_DIR}/log/"
}

step_admin() {
  hdr "Create initial administrator"
  if is_done admin; then log "Administrator already created."; return; fi
  if as_dspace "'${DSPACE_DIR}/bin/dspace' create-administrator -e '${ADMIN_EMAIL}' -f '${ADMIN_FIRST}' -l '${ADMIN_LAST}' -p '${ADMIN_PASS}' -c '${ADMIN_LANG}'"; then
    done_mark admin
  else
    warn "create-administrator failed (account may already exist)."
  fi
}

step_frontend() {
  hdr "DSpace ${DSPACE_VERSION} Angular frontend (build + deploy)"
  local src="${SRC_DIR}/dspace-angular-dspace-${DSPACE_VERSION}"
  if [[ ! -d "${src}" ]]; then
    download "${FRONTEND_URL}" "/tmp/dspace-angular-${DSPACE_VERSION}.tar.gz"
    tar xzf "/tmp/dspace-angular-${DSPACE_VERSION}.tar.gz" -C "${SRC_DIR}"
    chown -R "${DSPACE_USER}:${DSPACE_USER}" "${SRC_DIR}"
  fi

  log "npm install + production build (10-20 min, RAM hungry)..."
  as_dspace "cd '${src}' && (npm ci || npm install) && NODE_OPTIONS=--max-old-space-size=${UI_BUILD_HEAP_MB} npm run build:prod"

  as_dspace "pm2 delete dspace-ui >/dev/null 2>&1 || true"
  rm -rf "${UI_DIR}/dist"
  cp -R "${src}/dist" "${UI_DIR}/"
  mkdir -p "${UI_DIR}/config"

  cat > "${UI_DIR}/config/config.prod.yml" <<EOF
# Generated by install-dspace.sh on $(date)
ui:
  ssl: false
  host: ${UI_BIND}
  port: 4000
  nameSpace: /

rest:
  ssl: ${REST_SSL}
  host: ${DOMAIN}
  port: ${REST_PORT}
  nameSpace: /server
EOF

  cat > "${UI_DIR}/dspace-ui.json" <<EOF
{
  "apps": [
    {
      "name": "dspace-ui",
      "cwd": "${UI_DIR}",
      "script": "dist/server/main.js",
      "instances": ${PM2_INSTANCES},
      "exec_mode": "cluster",
      "max_memory_restart": "1G",
      "env": { "NODE_ENV": "production" }
    }
  ]
}
EOF
  chown -R "${DSPACE_USER}:${DSPACE_USER}" "${UI_DIR}"

  as_dspace "pm2 start '${UI_DIR}/dspace-ui.json' && pm2 save"
  env PATH="$PATH:/usr/bin" pm2 startup systemd -u "${DSPACE_USER}" --hp "/home/${DSPACE_USER}" >/dev/null
  systemctl enable "pm2-${DSPACE_USER}" >/dev/null 2>&1 || true
  wait_for_http "http://127.0.0.1:4000/" 180 || warn "UI not up yet — check: sudo -u ${DSPACE_USER} pm2 logs dspace-ui"
}

step_nginx() {
  [[ "${ENABLE_NGINX}" == "yes" ]] || { log "Nginx disabled — skipping."; return; }
  hdr "Nginx reverse proxy"
  apt-get install -y nginx
  cat > /etc/nginx/sites-available/dspace <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 2048M;          # max upload size
    proxy_read_timeout  600s;
    proxy_send_timeout  600s;

    # DSpace REST API (Tomcat)
    location /server {
        proxy_pass         http://127.0.0.1:8080/server;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-Forwarded-Host  \$host;
        proxy_set_header   X-Forwarded-Port  \$server_port;
    }

    # DSpace Angular UI (PM2 / Node SSR)
    location / {
        proxy_pass         http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/dspace /etc/nginx/sites-enabled/dspace
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ "${ENABLE_SSL}" == "yes" ]]; then
    hdr "Let's Encrypt SSL for ${DOMAIN}"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}" -m "${SSL_EMAIL}" --agree-tos --non-interactive --redirect || \
      warn "Certbot failed — check DNS for ${DOMAIN} points to this server, then run: certbot --nginx -d ${DOMAIN}"
  fi
}

step_firewall() {
  hdr "Firewall (UFW)"
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow OpenSSH
    if [[ "${ENABLE_NGINX}" == "yes" ]]; then
      ufw allow 'Nginx Full'
    else
      ufw allow 4000/tcp; ufw allow 8080/tcp
    fi
  else
    log "UFW not active — skipping. (Solr 8983 is bound to localhost only.)"
  fi
}

step_cron() {
  hdr "DSpace scheduled tasks (cron for '${DSPACE_USER}')"
  local d="${DSPACE_DIR}/bin/dspace"
  crontab -u "${DSPACE_USER}" - <<EOF
# DSpace maintenance — generated by install-dspace.sh
SHELL=/bin/bash
JAVA_OPTS="-Xmx512m -Dfile.encoding=UTF-8"
# Send daily/weekly/monthly subscription emails
0 1 * * *  ${d} subscription-send -f D > /dev/null 2>&1
0 1 * * 0  ${d} subscription-send -f W > /dev/null 2>&1
0 1 1 * *  ${d} subscription-send -f M > /dev/null 2>&1
# Generate thumbnails / full-text for new bitstreams
0 2 * * *  ${d} filter-media > /dev/null 2>&1
# Refresh OAI-PMH index
30 2 * * * ${d} oai import -c > /dev/null 2>&1
# Keep Solr in sync with the database
0 3 * * *  ${d} solr-database-resync > /dev/null 2>&1
# Clean up deleted bitstreams
0 4 * * 0  ${d} cleanup > /dev/null 2>&1
# Sitemaps for search engines
0 5 * * *  ${d} generate-sitemaps > /dev/null 2>&1
EOF
  systemctl enable --now cron
}

step_summary() {
  hdr "Installation summary"
  umask 077
  cat > "${CRED_FILE}" <<EOF
DSpace ${DSPACE_VERSION} — installed $(date)
-------------------------------------------------
UI URL          : ${UI_URL}
REST API        : ${SERVER_URL}/api
Admin email     : ${ADMIN_EMAIL}
Admin password  : ${ADMIN_PASS}
DB name/user    : ${DB_NAME} / ${DB_USER}
DB password     : ${DB_PASS}
Install dir     : ${DSPACE_DIR}
Source dir      : ${SRC_DIR}
UI dir          : ${UI_DIR}
Tomcat          : ${TOMCAT_DIR}   (systemctl status tomcat)
Solr            : http://127.0.0.1:8983/solr  (systemctl status solr)
UI process      : sudo -u ${DSPACE_USER} pm2 status
Logs            : ${DSPACE_DIR}/log/, ${TOMCAT_DIR}/logs/, pm2 logs dspace-ui
EOF
  cat "${CRED_FILE}"
  echo
  log "Credentials saved to ${CRED_FILE} (root-only). Change the admin password after first login."
}

# ============================== DRIVER =======================================
ALL_STEPS=(preflight packages node user database solr tomcat backend solr_cores \
           deploy_backend admin frontend nginx firewall cron summary)

if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL_STEPS[@]}"; exit 0; fi

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"; chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Keep generated passwords stable across partial re-runs
if [[ -f "${STATE_DIR}/secrets" ]]; then
  # shellcheck disable=SC1091
  source "${STATE_DIR}/secrets"
else
  ( umask 077; printf 'DB_PASS=%q\nADMIN_PASS=%q\n' "${DB_PASS}" "${ADMIN_PASS}" > "${STATE_DIR}/secrets" )
fi

STEPS=("$@"); [[ ${#STEPS[@]} -eq 0 ]] && STEPS=("${ALL_STEPS[@]}")
[[ " ${STEPS[*]} " == *" preflight "* ]] || step_preflight

START=$(date +%s)
for s in "${STEPS[@]}"; do
  declare -F "step_${s}" >/dev/null || die "Unknown step '${s}'. Use --list."
  "step_${s}"
done
log "Done in $(( ($(date +%s) - START) / 60 )) min. Open ${UI_URL}"
