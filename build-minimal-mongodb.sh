#!/bin/bash
set -e

# Error handling function
handle_error() {
  local error_code=$?
  echo "Error: Command failed with exit code $error_code"
  echo "Failed at step: $1"
  # Cleanup
  if [ ! -z "$CONTAINER_ID" ]; then
    echo "Cleaning up container..."
    docker stop $CONTAINER_ID 2>/dev/null || true
    docker rm $CONTAINER_ID 2>/dev/null || true
  fi
  exit $error_code
}

# Set trap to catch errors
trap 'handle_error "${BASH_COMMAND}"' ERR

# Accept parameters with defaults
MONGODB_VERSION=${1:-"6.0"}
MONGODB_USERNAME=${2:-"admin"}
MONGODB_PASSWORD=${3:-"mongoadmin"}

echo "Building minimal MongoDB image with:"
echo "- MongoDB version: $MONGODB_VERSION"
echo "- Admin username: $MONGODB_USERNAME"
echo "- Admin password: $MONGODB_PASSWORD"

# Step 1: Create a temporary container using a minimal Debian base
echo "Creating temporary container..."
CONTAINER_ID=$(docker run -d debian:slim-bullseye sleep infinity)

# Check container is running
docker ps | grep -q $CONTAINER_ID || {
  echo "Container failed to start properly!"
  exit 1
}

echo "Container created: $CONTAINER_ID"

# Step 2: Install only the essential MongoDB dependencies and MongoDB itself
docker exec $CONTAINER_ID bash -c "
apt-get update
apt-get install -y wget gnupg binutils
# Use modern GPG key handling
wget -qO - https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/mongodb-${MONGODB_VERSION}.gpg
echo \"deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/${MONGODB_VERSION} main\" | tee /etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list
apt-get update
apt-get install -y --no-install-recommends mongodb-org-server
apt-get clean

# Test MongoDB after installation
echo 'Testing MongoDB installation...'
if ! mongod --version; then
  echo 'MongoDB installation failed!'
  exit 1
fi

# Step 3: ULTRA-EXTREME minimization - nuclear approach with ZERO MERCY
mkdir -p /mongodb-minimal/{etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo/UTC,usr/share/zoneinfo/Etc,tmp,usr/bin}

# Copy only MongoDB server binary (no shell) and strip it to minimum size
cp /usr/bin/mongod /mongodb-minimal/usr/bin/
strip --strip-all /mongodb-minimal/usr/bin/mongod

# Find and copy ONLY required libraries with absolute paths
for lib in \$(ldd /usr/bin/mongod | grep -o \"/[^ ]*\" | sort -u); do
    if [ -f \"\$lib\" ]; then
        mkdir -p \"/mongodb-minimal\$(dirname \"\$lib\")\"
        cp \"\$lib\" \"/mongodb-minimal\$lib\"
        strip --strip-all \"/mongodb-minimal\$lib\"
    fi
done

# Find and copy libraries required by libraries (recursive dependencies)
for lib in \$(find /mongodb-minimal -name \"*.so*\"); do
    for dep in \$(ldd \$lib 2>/dev/null | grep -o \"/[^ ]*\" | sort -u); do
        if [ -f \"\$dep\" ] && [ ! -f \"/mongodb-minimal\$dep\" ]; then
            mkdir -p \"/mongodb-minimal\$(dirname \"\$dep\")\"
            cp \"\$dep\" \"/mongodb-minimal\$dep\"
            strip --strip-all \"/mongodb-minimal\$dep\"
        fi
    done
done

# Additional dependency handling to catch dynamically loaded libraries
for so in \$(find /mongodb-minimal -name \"*.so*\"); do
  # Extract direct references from the .so file
  for ref in \$(objdump -p \"\$so\" | grep NEEDED | awk '{print \$2}'); do
    # Find the full path of each referenced library
    full_path=\$(find /lib /usr/lib -name \"\$ref\" | head -1)
    if [ -n \"\$full_path\" ] && [ ! -f \"/mongodb-minimal\$full_path\" ]; then
      mkdir -p \"/mongodb-minimal\$(dirname \"\$full_path\")\"
      cp \"\$full_path\" \"/mongodb-minimal\$full_path\"
      strip --strip-all \"/mongodb-minimal\$full_path\"
    fi
  done
done

# Copy only the absolutely essential timezone data (MongoDB needs this)
cp -r /usr/share/zoneinfo/UTC /mongodb-minimal/usr/share/zoneinfo/
cp -r /usr/share/zoneinfo/Etc /mongodb-minimal/usr/share/zoneinfo/

# Create absolute minimal MongoDB configuration
cat > /mongodb-minimal/etc/mongod.conf << EOF
storage:
    dbPath: /var/lib/mongodb
    journal:
        enabled: true
systemLog:
    destination: file
    path: /var/log/mongodb/mongod.log
    logAppend: true
net:
    port: 27017
    bindIp: 0.0.0.0
processManagement:
    timeZoneInfo: /usr/share/zoneinfo
    fork: false
security:
    authorization: enabled
EOF

# Create passwd entry for MongoDB user (uid 999 is common for mongodb)
echo \"mongodb:x:999:999::/var/lib/mongodb:/\" > /mongodb-minimal/etc/passwd
echo \"mongodb:x:999:\" > /mongodb-minimal/etc/group

# Create an empty /etc/nsswitch.conf to avoid getpwnam issues
echo \"passwd: files\" > /mongodb-minimal/etc/nsswitch.conf
echo \"group: files\" >> /mongodb-minimal/etc/nsswitch.conf

# Create JavaScript initialization file with user creation logic
cat > /mongodb-minimal/var/lib/mongodb/init.js << EOF
db = db.getSiblingDB(\"admin\");
db.createUser({
  user: \"${MONGODB_USERNAME}\",
  pwd: \"${MONGODB_PASSWORD}\",
  roles: [{role: \"root\", db: \"admin\"}]
});
EOF

# NUKE EVERYTHING, then restore only our minimal copy
rm -rf /* 2>/dev/null || true
mv /mongodb-minimal/* /
rm -rf /mongodb-minimal

# Set proper permissions
chmod 755 /usr/bin/mongod
mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R 999:999 /var/lib/mongodb /var/log/mongodb
chown 999:999 /var/lib/mongodb/init.js

# Create a flag file that will trigger initialization on first container start
touch /var/lib/mongodb/.initialized
chown 999:999 /var/lib/mongodb/.initialized
"

# Step 4: Export the container as a new image with direct mongod command and init logic
docker commit --change='USER mongodb' \
    --change='CMD ["sh", "-c", "if [ -f /var/lib/mongodb/.initialized ] && [ ! -f /var/lib/mongodb/.completed ]; then mongod --fork --logpath /var/log/mongodb/init.log --dbpath /var/lib/mongodb; mongod --eval \"load(\\\"/var/lib/mongodb/init.js\\\")\"; mongod --shutdown; rm /var/lib/mongodb/init.js; touch /var/lib/mongodb/.completed; fi; exec mongod --config /etc/mongod.conf"]' \
    --change='EXPOSE 27017' \
    --change='VOLUME ["/var/lib/mongodb", "/var/log/mongodb"]' \
    --change='HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD [ "mongod", "--eval", "db.adminCommand(\'ping\')", "--quiet" ]' \
    $CONTAINER_ID minimal-mongodb:latest

# Step 5: Clean up
docker stop $CONTAINER_ID
docker rm $CONTAINER_ID

echo "Minimal MongoDB image created as 'minimal-mongodb:latest'"
echo "Image details:"
docker images minimal-mongodb:latest
echo ""
echo "MongoDB credentials:"
echo "Username: $MONGODB_USERNAME"
echo "Password: $MONGODB_PASSWORD"
echo ""
echo "IMPORTANT: Change the default password after first login!"
echo "Usage example: docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest"
