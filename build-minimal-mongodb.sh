#!/bin/bash
set -e

# Step 1: Create a temporary container using a minimal Debian base
CONTAINER_ID=$(docker run -d debian:slim-bullseye sleep infinity)

# Step 2: Install only the essential MongoDB dependencies and MongoDB itself
docker exec $CONTAINER_ID bash -c '
apt-get update
apt-get install -y wget gnupg binutils
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add -
echo "deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list
apt-get update
apt-get install -y --no-install-recommends mongodb-org-server
apt-get clean

# Step 3: ULTRA-EXTREME minimization - nuclear approach with ZERO MERCY
mkdir -p /mongodb-minimal/{etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo/UTC,usr/share/zoneinfo/Etc,tmp,usr/bin}

# Copy only MongoDB server binary (no shell) and strip it to minimum size
cp /usr/bin/mongod /mongodb-minimal/usr/bin/
strip --strip-all /mongodb-minimal/usr/bin/mongod

# Find and copy ONLY required libraries with absolute paths
for lib in $(ldd /usr/bin/mongod | grep -o "/[^ ]*" | sort -u); do
    if [ -f "$lib" ]; then
        mkdir -p "/mongodb-minimal$(dirname "$lib")"
        cp "$lib" "/mongodb-minimal$lib"
        strip --strip-all "/mongodb-minimal$lib"
    fi
done

# Find and copy libraries required by libraries (recursive dependencies)
for lib in $(find /mongodb-minimal -name "*.so*"); do
    for dep in $(ldd $lib 2>/dev/null | grep -o "/[^ ]*" | sort -u); do
        if [ -f "$dep" ] && [ ! -f "/mongodb-minimal$dep" ]; then
            mkdir -p "/mongodb-minimal$(dirname "$dep")"
            cp "$dep" "/mongodb-minimal$dep"
            strip --strip-all "/mongodb-minimal$dep"
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
echo "mongodb:x:999:999::/var/lib/mongodb:/" > /mongodb-minimal/etc/passwd
echo "mongodb:x:999:" > /mongodb-minimal/etc/group

# Create an empty /etc/nsswitch.conf to avoid getpwnam issues
echo "passwd: files" > /mongodb-minimal/etc/nsswitch.conf
echo "group: files" >> /mongodb-minimal/etc/nsswitch.conf

# NUKE EVERYTHING, then restore only our minimal copy
rm -rf /* 2>/dev/null || true
mv /mongodb-minimal/* /
rm -rf /mongodb-minimal

# Set proper permissions
chmod 755 /usr/bin/mongod
mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R 999:999 /var/lib/mongodb /var/log/mongodb

# Start MongoDB temporarily without auth to create the admin user
mongod --fork --logpath /var/log/mongodb/init.log --dbpath /var/lib/mongodb

# Create a default admin user with password "mongoadmin"
# Users should change this password after first login
mongod --eval "db = db.getSiblingDB(\"admin\"); db.createUser({user:\"admin\", pwd:\"mongoadmin\", roles:[{role:\"root\", db:\"admin\"}]})"

# Stop the temporary MongoDB instance
mongod --shutdown

# Create a file indicating this is a pre-configured instance
touch /var/lib/mongodb/.preconfigured
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
echo ""
echo "Default admin credentials:"
echo "Username: admin"
echo "Password: mongoadmin"
echo ""
echo "IMPORTANT: Change the default password after first login!"
