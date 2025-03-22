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

# Step 3: EXTREME minimization - maximum deletion approach
# First, identify and save the absolute essentials
mkdir -p /mongodb-preserve
cp /usr/bin/mongod /mongodb-preserve/
cp /usr/bin/mongosh /mongodb-preserve/

# Find and copy all required dynamic libraries
for lib in $(ldd /usr/bin/mongod | grep -o "/[^ ]*" | sort -u); do
  if [ -f "$lib" ]; then
    dir=$(dirname "$lib")
    mkdir -p "/mongodb-preserve$dir"
    cp "$lib" "/mongodb-preserve$lib"
  fi
done

for lib in $(ldd /usr/bin/mongosh | grep -o "/[^ ]*" | sort -u); do
  if [ -f "$lib" ]; then
    dir=$(dirname "$lib")
    mkdir -p "/mongodb-preserve$dir"
    cp "$lib" "/mongodb-preserve$lib"
  fi
done

# Save minimal configuration directories
mkdir -p /mongodb-preserve/etc
mkdir -p /mongodb-preserve/var/lib/mongodb
mkdir -p /mongodb-preserve/var/log/mongodb
mkdir -p /mongodb-preserve/tmp
mkdir -p /mongodb-preserve/usr/share/zoneinfo/UTC
mkdir -p /mongodb-preserve/usr/share/zoneinfo/Etc

# Copy timezone data (MongoDB needs this)
cp -r /usr/share/zoneinfo/UTC /mongodb-preserve/usr/share/zoneinfo/
cp -r /usr/share/zoneinfo/Etc /mongodb-preserve/usr/share/zoneinfo/

# Create MongoDB user backup
grep "^mongodb:" /etc/passwd > /mongodb-preserve/passwd
grep "^mongodb:" /etc/group > /mongodb-preserve/group

# Save minimal MongoDB configuration
cat > /mongodb-preserve/mongod.conf << EOF
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

# Now REMOVE EVERYTHING except core directories
rm -rf /bin/* /sbin/* /usr/bin/* /usr/sbin/* /usr/local/bin/* /usr/local/sbin/*
rm -rf /etc/*
rm -rf /usr/share/*
rm -rf /usr/lib/*
rm -rf /var/lib/*
rm -rf /var/cache/*
rm -rf /var/log/*
rm -rf /tmp/*
rm -rf /root/*
rm -rf /home/*

# Restore only what MongoDB needs from our preserved copies
cp -r /mongodb-preserve/* /
cat /mongodb-preserve/passwd >> /etc/passwd
cat /mongodb-preserve/group >> /etc/group
mv /mongod.conf /etc/mongod.conf
chmod 755 /usr/bin/mongod /usr/bin/mongosh
chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

# Clean up preservation directory
rm -rf /mongodb-preserve
'

# Step 4: Export the container as a new image with direct mongod command
docker commit --change='USER mongodb' \
              --change='CMD ["mongod", "--config", "/etc/mongod.conf"]' \
              --change='EXPOSE 27017' \
              --change='VOLUME ["/var/lib/mongodb", "/var/log/mongodb"]' \
              $CONTAINER_ID minimal-mongodb:latest

# Step 5: Clean up
docker stop $CONTAINER_ID
docker rm $CONTAINER_ID

echo "Minimal MongoDB image created as 'minimal-mongodb:latest'"
echo "Image details:"
docker images minimal-mongodb:latest