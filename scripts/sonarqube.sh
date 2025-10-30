#!/usr/bin/env bash
set -euo pipefail

SONAR_VERSION="10.3.0.82913"
SONAR_DIR="/opt/sonarqube"
SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"
DB_NAME="sonarqube"
DB_USER="sonar"
DB_PASS="StrongPassword123!"

export DEBIAN_FRONTEND=noninteractive

echo "[+] Installing dependencies"
apt-get update -y
apt-get install -y unzip wget curl gnupg apt-transport-https openjdk-17-jdk postgresql postgresql-contrib

echo "[+] Ensuring PostgreSQL is running"
systemctl enable --now postgresql

echo "[+] Configuring PostgreSQL database and user (idempotent)"
# Create role if missing
sudo -u postgres psql -v ON_ERROR_STOP=1 -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"

# Create DB if missing (must be outside a transaction)
sudo -u postgres psql -v ON_ERROR_STOP=1 -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

# Grant privileges (harmless if already owned)
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"

# Ensure local password auth
if ! grep -E '^host\s+all\s+all\s+127\.0\.0\.1/32\s+md5' /etc/postgresql/*/main/pg_hba.conf >/dev/null; then
  echo 'host    all             all             127.0.0.1/32            md5' | tee -a /etc/postgresql/*/main/pg_hba.conf >/dev/null
  systemctl restart postgresql
fi

echo "[+] Setting kernel parameter vm.max_map_count"
sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

echo "[+] Downloading SonarQube if needed"
mkdir -p /opt
if [ ! -d "${SONAR_DIR}" ]; then
  cd /opt
  if [ ! -f "${SONAR_ZIP}" ]; then
    wget -q "${SONAR_URL}"
  fi
  unzip -q "${SONAR_ZIP}"
  mv "sonarqube-${SONAR_VERSION}" "${SONAR_DIR}"
fi

echo "[+] Creating sonarqube system user and setting ownership"
if ! id "sonarqube" >/dev/null 2>&1; then
  useradd --system --home-dir "${SONAR_DIR}" --shell /bin/bash sonarqube
fi
mkdir -p "${SONAR_DIR}/"{logs,data,temp,extensions}
chown -R sonarqube:sonarqube "${SONAR_DIR}"

echo "[+] Configuring sonar.properties (DB, bind address, port)"
sed -i 's|^#\?sonar.jdbc.username=.*|sonar.jdbc.username='"${DB_USER}"'|' "${SONAR_DIR}/conf/sonar.properties"
sed -i 's|^#\?sonar.jdbc.password=.*|sonar.jdbc.password='"${DB_PASS}"'|' "${SONAR_DIR}/conf/sonar.properties"
sed -i 's|^#\?sonar.jdbc.url=.*|sonar.jdbc.url=jdbc:postgresql://localhost/'"${DB_NAME}"'|' "${SONAR_DIR}/conf/sonar.properties"
sed -i 's|^#\?sonar.web.host=.*|sonar.web.host=0.0.0.0|' "${SONAR_DIR}/conf/sonar.properties"
sed -i 's|^#\?sonar.web.port=.*|sonar.web.port=9000|' "${SONAR_DIR}/conf/sonar.properties"

echo "[+] Ensuring sonar.sh drops privileges"
if [ -f "${SONAR_DIR}/bin/linux-x86-64/sonar.sh" ]; then
  sed -i 's/^#\?RUN_AS_USER=.*/RUN_AS_USER=sonarqube/' "${SONAR_DIR}/bin/linux-x86-64/sonar.sh"
fi

echo "[+] Creating systemd unit"
tee /etc/systemd/system/sonar.service >/dev/null <<'EOL'
[Unit]
Description=SonarQube service
After=syslog.target network.target postgresql.service
Wants=postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=65536
LimitNPROC=4096
Environment="JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
Environment="PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOL

echo "[+] Enabling and starting SonarQube"
systemctl daemon-reload
systemctl enable sonar
systemctl restart sonar

echo "[+] Optionally allow port 9000 via UFW if active"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 9000/tcp || true
fi

echo "[✓] SonarQube installation completed. It may take 1–3 minutes to become operational."
