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

# Step 3: Advanced cleanup to create truly minimal image
# Remove package management tools after installation
apt-get -y --purge autoremove
apt-get -y --purge remove gnupg wget
rm -rf /var/lib/apt /var/lib/dpkg

# Remove all unnecessary directories
rm -rf /usr/share/doc /usr/share/man /usr/share/info
rm -rf /usr/share/locale/*
rm -rf /var/cache/* /var/tmp/* /tmp/*
rm -rf /usr/share/common-licenses
rm -rf /usr/share/pixmaps /usr/share/applications

# Remove all log files except MongoDB log directory
find /var/log -type f -delete

# Keep only minimal zoneinfo data (MongoDB needs this)
find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -not -name UTC -not -name Etc -exec rm -rf {} \;

# Strip binaries to reduce size
find /usr/bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /usr/sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
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