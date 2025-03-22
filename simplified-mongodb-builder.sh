#!/bin/bash
set -e

# Error handling function
handle_error() {
  local error_code=$?
  echo "Error: Command failed with exit code $error_code"
  echo "Failed at step: $1"
  
  # Cleanup
  if [ -n "$CONTAINER_ID" ]; then
    echo "Cleaning up container..."
    docker stop $CONTAINER_ID 2>/dev/null || true
    docker rm $CONTAINER_ID 2>/dev/null || true
  fi
  exit $error_code
}

# Set trap to catch errors
trap 'handle_error "${BASH_COMMAND}"' ERR

# Accept parameters with defaults
MONGODB_VERSION="${1:-latest}"
MONGODB_USERNAME="${2:-admin}"
MONGODB_PASSWORD="${3:-admin}"

echo "Building minimal MongoDB image with:"
echo "- MongoDB version: $MONGODB_VERSION"
echo "- Admin username: $MONGODB_USERNAME"
echo "- Admin password: $MONGODB_PASSWORD"

# Step 1: Pull the official MongoDB image
echo "Pulling official MongoDB image (mongodb/mongodb-community-server:$MONGODB_VERSION)..."
docker pull mongodb/mongodb-community-server:$MONGODB_VERSION

# Step 2: Create a temporary container
echo "Creating temporary container..."
CONTAINER_ID=$(docker run -d mongodb/mongodb-community-server:$MONGODB_VERSION)

# Check container is running
if ! docker ps | grep -q "$CONTAINER_ID"; then
  echo "Container failed to start properly!"
  exit 1
fi

echo "Container created: $CONTAINER_ID"

# Step 3: Create a minimal directory structure for essential files
echo "Creating minimal directory structure..."
docker exec $CONTAINER_ID bash -c "mkdir -p /tmp/mongodb-minimal/{bin,lib,etc/mongodb,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo}"

# Step 4: Identify the MongoDB binary and copy it
echo "Locating and copying MongoDB binary..."
docker exec $CONTAINER_ID bash -c "MONGOD_PATH=\$(which mongod || find / -name mongod -type f -executable | grep -v 'mongodb-database-tools' | head -1)
if [ -z \"\$MONGOD_PATH\" ]; then
  echo 'MongoDB binary not found!'
  exit 1
fi
echo \"Found MongoDB binary at \$MONGOD_PATH\"
cp \"\$MONGOD_PATH\" /tmp/mongodb-minimal/bin/
strip --strip-all /tmp/mongodb-minimal/bin/mongod 2>/dev/null || true"

# Step 5: Copy all required libraries
echo "Copying required libraries..."
docker exec $CONTAINER_ID bash -c "MONGOD_PATH=\$(which mongod || find / -name mongod -type f -executable | grep -v 'mongodb-database-tools' | head -1)
for lib in \$(ldd \"\$MONGOD_PATH\" 2>/dev/null | grep -o '/[^ ]*' | sort -u); do
  if [ -f \"\$lib\" ]; then
    lib_dir=\$(dirname \"\$lib\")
    mkdir -p \"/tmp/mongodb-minimal\$lib_dir\"
    cp \"\$lib\" \"/tmp/mongodb-minimal\$lib\"
    strip --strip-all \"/tmp/mongodb-minimal\$lib\" 2>/dev/null || true
  fi
done"

# Step 6: Handle recursive dependencies
echo "Resolving recursive dependencies..."
docker exec $CONTAINER_ID bash -c "for lib in \$(find /tmp/mongodb-minimal -name \"*.so*\"); do
  for dep in \$(ldd \"\$lib\" 2>/dev/null | grep -o '/[^ ]*' | sort -u); do
    if [ -f \"\$dep\" ] && [ ! -f \"/tmp/mongodb-minimal\$dep\" ]; then
      dep_dir=\$(dirname \"\$dep\")
      mkdir -p \"/tmp/mongodb-minimal\$dep_dir\"
      cp \"\$dep\" \"/tmp/mongodb-minimal\$dep\"
      strip --strip-all \"/tmp/mongodb-minimal\$dep\" 2>/dev/null || true
    fi
  done
done"

# Step 7: Copy essential timezone data (MongoDB needs this)
echo "Copying essential timezone data..."
docker exec $CONTAINER_ID bash -c "if [ -d /usr/share/zoneinfo/UTC ]; then
  cp -r /usr/share/zoneinfo/UTC /tmp/mongodb-minimal/usr/share/zoneinfo/
fi
if [ -d /usr/share/zoneinfo/Etc ]; then
  cp -r /usr/share/zoneinfo/Etc /tmp/mongodb-minimal/usr/share/zoneinfo/
fi"

# Step 8: Create keyfile for authentication
echo "Creating MongoDB keyfile..."
docker exec $CONTAINER_ID bash -c "openssl rand -base64 756 > /tmp/mongodb-minimal/etc/mongodb/keyfile
chmod 400 /tmp/mongodb-minimal/etc/mongodb/keyfile"

# Step 9: Create MongoDB configuration file
echo "Creating MongoDB configuration file..."
docker exec $CONTAINER_ID bash -c "cat > /tmp/mongodb-minimal/etc/mongod.conf << 'EOF'
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
  keyFile: /etc/mongodb/keyfile
EOF"

# Step 10: Copy passwd and group entries for MongoDB user
echo "Creating user entries..."
docker exec $CONTAINER_ID bash -c "echo \"mongodb:x:999:999::/var/lib/mongodb:/\" > /tmp/mongodb-minimal/etc/passwd
echo \"mongodb:x:999:\" > /tmp/mongodb-minimal/etc/group
echo \"passwd: files\" > /tmp/mongodb-minimal/etc/nsswitch.conf
echo \"group: files\" >> /tmp/mongodb-minimal/etc/nsswitch.conf"

# Step 11: Start MongoDB to create admin user
echo "Starting MongoDB to create admin user..."
docker exec $CONTAINER_ID bash -c "mongod --fork --dbpath /var/lib/mongodb --logpath /var/log/mongodb/init.log --bind_ip_all

# Wait for MongoDB to start properly
echo \"Waiting for MongoDB to become available...\"
timeout=30
for ((i=1; i<=timeout; i++)); do
  if nc -z localhost 27017 || wget -q --spider http://localhost:27017 || curl -s http://localhost:27017 > /dev/null; then
    echo \"MongoDB is available after \$i seconds.\"
    break
  fi
  if [ \$i -eq \$timeout ]; then
    echo \"Error: MongoDB did not start within \$timeout seconds.\"
    cat /var/log/mongodb/init.log
    exit 1
  fi
  sleep 1
  echo -n \".\"
done

# Create admin user
echo \"Creating admin user: ${MONGODB_USERNAME}\"
ESCAPED_USERNAME=$(printf '%s' \"${MONGODB_USERNAME}\" | sed 's/\"/\\\\\"/g')
ESCAPED_PASSWORD=$(printf '%s' \"${MONGODB_PASSWORD}\" | sed 's/\"/\\\\\"/g')

# Try to use mongosh if available, otherwise fall back to mongo
if command -v mongosh > /dev/null; then
  mongosh --host 127.0.0.1 --eval \"db = db.getSiblingDB('admin'); db.createUser({user:'${ESCAPED_USERNAME}', pwd:'${ESCAPED_PASSWORD}', roles:[{role:'root', db:'admin'}]})\"
elif command -v mongo > /dev/null; then
  mongo --host 127.0.0.1 --eval \"db = db.getSiblingDB('admin'); db.createUser({user:'${ESCAPED_USERNAME}', pwd:'${ESCAPED_PASSWORD}', roles:[{role:'root', db:'admin'}]})\"
else
  echo \"Neither mongosh nor mongo shell found. Cannot create admin user.\"
  exit 1
fi

# Shut down MongoDB
MONGODB_PID=\$(pgrep -x mongod)
if [ -n \"\$MONGODB_PID\" ]; then
  kill -9 \"\$MONGODB_PID\"
  sleep 3
fi"

# Step 12: Copy initialized data directory to preserve admin user
echo "Copying initialized data directory..."
docker exec $CONTAINER_ID bash -c "mkdir -p /tmp/mongodb-minimal/var/lib/mongodb
cp -a /var/lib/mongodb/* /tmp/mongodb-minimal/var/lib/mongodb/ 2>/dev/null || true"

# Step 13: Set proper permissions
echo "Setting proper permissions..."
docker exec $CONTAINER_ID bash -c "chmod 755 /tmp/mongodb-minimal/bin/mongod
chmod 400 /tmp/mongodb-minimal/etc/mongodb/keyfile
chmod 750 /tmp/mongodb-minimal/var/lib/mongodb
chmod 750 /tmp/mongodb-minimal/var/log/mongodb"

# Step 14: Create a minimal Debian container to receive our files
echo "Creating minimal base container..."
BASE_CONTAINER_ID=$(docker run -d debian:slim sleep infinity)

# Step 15: Copy the minimal filesystem from the MongoDB container to the Debian container
echo "Copying minimal MongoDB files to base container..."
docker cp $CONTAINER_ID:/tmp/mongodb-minimal/. $BASE_CONTAINER_ID:/

# Step 16: Set ownership in the destination container
docker exec $BASE_CONTAINER_ID bash -c "chown -R 999:999 /var/lib/mongodb /var/log/mongodb /etc/mongodb/keyfile"

# Step 17: Commit the new minimal container
echo "Creating minimal MongoDB image..."
docker commit \
  --change="USER mongodb" \
  --change="CMD [\"bin/mongod\", \"--config\", \"/etc/mongod.conf\"]" \
  --change="EXPOSE 27017" \
  --change="VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]" \
  --change="HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD [ \"bin/mongod\", \"--eval\", \"db.adminCommand('ping')\", \"--quiet\" ]" \
  $BASE_CONTAINER_ID minimal-mongodb:latest

# Step 18: Clean up
echo "Cleaning up..."
docker stop $CONTAINER_ID $BASE_CONTAINER_ID
docker rm $CONTAINER_ID $BASE_CONTAINER_ID

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
