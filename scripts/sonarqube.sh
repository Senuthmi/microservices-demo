#!/bin/bash
set -e

# Update and install dependencies
sudo apt update -y
sudo apt install unzip wget curl gnupg apt-transport-https openjdk-17-jdk postgresql postgresql-contrib -y

# Configure PostgreSQL
sudo -u postgres psql <<EOF
CREATE DATABASE sonarqube;
CREATE USER sonar WITH ENCRYPTED PASSWORD 'StrongPassword123!';
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# Download SonarQube
cd /opt
sudo wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-10.3.0.82913.zip
sudo unzip sonarqube-10.3.0.82913.zip
sudo mv sonarqube-10.3.0.82913 sonarqube
sudo chown -R $USER:$USER /opt/sonarqube

# Configure sonar.properties
sudo sed -i 's|#sonar.jdbc.username=.*|sonar.jdbc.username=sonar|' /opt/sonarqube/conf/sonar.properties
sudo sed -i 's|#sonar.jdbc.password=.*|sonar.jdbc.password=StrongPassword123!|' /opt/sonarqube/conf/sonar.properties
sudo sed -i 's|#sonar.jdbc.url=.*|sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube|' /opt/sonarqube/conf/sonar.properties
sudo sed -i 's|#sonar.web.host=.*|sonar.web.host=0.0.0.0|' /opt/sonarqube/conf/sonar.properties

# Create SonarQube systemd service
sudo tee /etc/systemd/system/sonar.service > /dev/null <<EOL
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=$USER
Group=$USER
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOL

# Start SonarQube service
sudo systemctl daemon-reload
sudo systemctl enable sonar
sudo systemctl start sonar
