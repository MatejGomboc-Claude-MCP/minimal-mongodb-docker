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

# Step 3: Ultra-aggressive cleanup for absolute minimal image
# Remove package management tools after installation
apt-get -y --purge autoremove
apt-get -y --purge remove gnupg wget
rm -rf /var/lib/apt /var/lib/dpkg /usr/bin/apt* /usr/bin/dpkg* /sbin/dpkg* /usr/share/dpkg

# Identify MongoDB binaries and libraries to preserve
mkdir -p /tmp/mongodb-deps
echo "/usr/bin/mongod" > /tmp/mongodb-deps/preserve.txt
echo "/usr/bin/mongosh" >> /tmp/mongodb-deps/preserve.txt
ldd /usr/bin/mongod | grep -o "/[^ ]*" >> /tmp/mongodb-deps/preserve.txt
ldd /usr/bin/mongosh | grep -o "/[^ ]*" >> /tmp/mongodb-deps/preserve.txt

# Remove entire unnecessary directory trees
rm -rf /usr/share/doc /usr/share/man /usr/share/info
rm -rf /usr/share/locale/*
rm -rf /var/cache/* /var/tmp/* /tmp/{*,.[!.],..?*} 2> /dev/null || true
rm -rf /usr/share/common-licenses
rm -rf /usr/share/pixmaps /usr/share/applications
find /var/log -type f -delete

# Keep only UTC and Etc timezones (MongoDB needs these)
find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -not -name UTC -not -name Etc -exec rm -rf {} \;

# Strip binaries to reduce size
find /usr/bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /usr/sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true
find /sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true

# Remove non-essential binaries (preserving those needed by MongoDB)
for f in $(find /usr/bin /usr/sbin /bin /sbin -type f); do
  if ! grep -q "$f" /tmp/mongodb-deps/preserve.txt; then
    rm -f "$f" 2>/dev/null || true
  fi
done

# Remove all non-MongoDB init scripts
rm -rf /etc/init.d/* /etc/rc*

# Remove all cron-related files
rm -rf /etc/cron* /var/spool/cron

# Remove unnecessary services and configs
rm -rf /etc/logrotate* /etc/ppp /etc/ssh /etc/modprobe.d /etc/modules-load.d

# Remove any unused Python files (MongoDB is C++)
rm -rf /usr/lib/python*

# Remove non-C locales
rm -rf /usr/share/locale /usr/lib/locale
mkdir -p /usr/share/locale/C.UTF-8

# Clean up temporary files
rm -rf /tmp/mongodb-deps
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