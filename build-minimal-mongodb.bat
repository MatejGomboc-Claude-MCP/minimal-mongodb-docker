@echo off
setlocal enabledelayedexpansion

REM Step 1: Create a temporary container using a minimal Debian base
FOR /F "tokens=*" %%i IN ('docker run -d debian:slim-bullseye sleep infinity') DO SET CONTAINER_ID=%%i

REM Step 2: Install MongoDB and dependencies
docker exec %CONTAINER_ID% bash -c "apt-get update && apt-get install -y wget gnupg binutils && wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add - && echo \"deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main\" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list && apt-get update && apt-get install -y --no-install-recommends mongodb-org-server mongodb-org-shell && apt-get clean"

REM Step 3: ULTRA-EXTREME minimization - nuclear approach
docker exec %CONTAINER_ID% bash -c "
# Create base minimal structure
mkdir -p /mongodb-minimal/{bin,lib,etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo/UTC,usr/share/zoneinfo/Etc,tmp,usr/bin}

# Copy MongoDB binaries and strip them to minimum size
cp /usr/bin/mongod /mongodb-minimal/usr/bin/
strip --strip-all /mongodb-minimal/usr/bin/mongod
cp /usr/bin/mongosh /mongodb-minimal/usr/bin/
strip --strip-all /mongodb-minimal/usr/bin/mongosh

# Essential: Add a minimal shell for emergency access
cp /bin/busybox /mongodb-minimal/bin/ 2>/dev/null || cp /bin/dash /mongodb-minimal/bin/ 2>/dev/null || cp /bin/sh /mongodb-minimal/bin/

# Find and copy ONLY required libraries with absolute paths
for bin in /mongodb-minimal/usr/bin/mongod /mongodb-minimal/usr/bin/mongosh; do
  for lib in \$(ldd /usr/bin/\$(basename \$bin) | grep -o \"/[^ ]*\" | sort -u); do
    if [ -f \"\$lib\" ]; then
      mkdir -p \"/mongodb-minimal\$(dirname \"\$lib\")\"
      cp \"\$lib\" \"/mongodb-minimal\$lib\"
      strip --strip-unneeded \"/mongodb-minimal\$lib\"
    fi
  done
done

# Find and copy libraries required by libraries (recursive dependencies)
for lib in \$(find /mongodb-minimal -name \"*.so*\"); do
  for dep in \$(ldd \$lib 2>/dev/null | grep -o \"/[^ ]*\" | sort -u); do
    if [ -f \"\$dep\" ] && [ ! -f \"/mongodb-minimal\$dep\" ]; then
      mkdir -p \"/mongodb-minimal\$(dirname \"\$dep\")\"
      cp \"\$dep\" \"/mongodb-minimal\$dep\"
      strip --strip-unneeded \"/mongodb-minimal\$dep\"
    fi
  done
done

# Copy only the absolutely essential timezone data (MongoDB needs this)
cp -r /usr/share/zoneinfo/UTC /mongodb-minimal/usr/share/zoneinfo/
cp -r /usr/share/zoneinfo/Etc /mongodb-minimal/usr/share/zoneinfo/

# Create minimal MongoDB configuration
cat > /mongodb-minimal/etc/mongod.conf << EOF
# mongod.conf - absolute minimal configuration
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
echo \"mongodb:x:999:999:mongodb user:/var/lib/mongodb:/bin/false\" > /mongodb-minimal/etc/passwd
echo \"mongodb:x:999:\" > /mongodb-minimal/etc/group

# Create an empty /etc/nsswitch.conf to avoid getpwnam issues
echo \"passwd: files\" > /mongodb-minimal/etc/nsswitch.conf
echo \"group: files\" >> /mongodb-minimal/etc/nsswitch.conf

# Create a bare minimum root directory
mkdir -p /mongodb-minimal/root

# NUKE EVERYTHING, then restore only our minimal copy
rm -rf /* 2>/dev/null || true
mv /mongodb-minimal/* /
rm -rf /mongodb-minimal

# Set proper permissions
chmod 755 /usr/bin/mongod /usr/bin/mongosh
mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R 999:999 /var/lib/mongodb /var/log/mongodb
"

REM Step 4: Export as new image with direct mongod command
docker commit --change="USER mongodb" ^
              --change="CMD [\"mongod\", \"--config\", \"/etc/mongod.conf\"]" ^
              --change="EXPOSE 27017" ^
              --change="VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]" ^
              %CONTAINER_ID% minimal-mongodb:latest

REM Step 5: Cleanup
docker stop %CONTAINER_ID%
docker rm %CONTAINER_ID%

echo Minimal MongoDB image created as 'minimal-mongodb:latest'
echo Image details:
docker images minimal-mongodb:latest