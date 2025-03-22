#!/bin/bash
set -e

# Step 1: Create a temporary container using a minimal Debian base
CONTAINER_ID=$(docker run -d debian:slim-bullseye sleep infinity)

# Step 2: Install only the essential MongoDB dependencies and MongoDB itself
docker exec $CONTAINER_ID bash -c '
apt-get update
apt-get install -y wget gnupg
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add -
echo "deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list
apt-get update
apt-get install -y --no-install-recommends mongodb-org-server mongodb-org-shell
apt-get clean
rm -rf /var/lib/apt/lists/*

# Step 3: Remove unnecessary files to reduce image size
rm -rf /usr/share/doc /usr/share/man /tmp/* /var/tmp/* /var/cache/apt/*
'

# Step 4: Use default Debian MongoDB configuration with minor adjustments
docker exec $CONTAINER_ID bash -c '
mkdir -p /var/log/mongodb
mkdir -p /var/lib/mongodb
chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

# Use the default config location but modify for container use
cat > /etc/mongod.conf << EOF
# mongod.conf

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true

# Where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# Network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

# Process management options
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  fork: false

# Security settings
security:
  authorization: enabled
EOF

# Ensure proper permissions
chmod 755 /usr/bin/mongod
'

# Step 5: Export the container as a new image with direct mongod command
docker commit --change='USER mongodb' \
              --change='CMD ["mongod", "--config", "/etc/mongod.conf"]' \
              --change='EXPOSE 27017' \
              --change='VOLUME ["/var/lib/mongodb", "/var/log/mongodb"]' \
              $CONTAINER_ID minimal-mongodb:latest

# Step 6: Clean up
docker stop $CONTAINER_ID
docker rm $CONTAINER_ID

echo "Minimal MongoDB image created as 'minimal-mongodb:latest'"
echo "Image details:"
docker images minimal-mongodb:latest