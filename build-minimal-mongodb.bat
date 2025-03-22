@echo off
setlocal enabledelayedexpansion

REM Step 1: Create a temporary container using a minimal Debian base
FOR /F "tokens=*" %%i IN ('docker run -d debian:slim-bullseye sleep infinity') DO SET CONTAINER_ID=%%i

REM Step 2: Install MongoDB and dependencies
docker exec %CONTAINER_ID% bash -c "apt-get update && apt-get install -y wget gnupg && wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add - && echo \"deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main\" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list && apt-get update && apt-get install -y --no-install-recommends mongodb-org-server mongodb-org-shell && apt-get clean && rm -rf /var/lib/apt/lists/*"

REM Step 3: Remove unnecessary files
docker exec %CONTAINER_ID% bash -c "rm -rf /usr/share/doc /usr/share/man /tmp/* /var/tmp/* /var/cache/apt/*"

REM Step 4: Use default Debian MongoDB configuration and set permissions
docker exec %CONTAINER_ID% bash -c "mkdir -p /var/log/mongodb && mkdir -p /var/lib/mongodb && chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb"

REM Create identical configuration file using here-doc approach
docker exec %CONTAINER_ID% bash -c "cat > /etc/mongod.conf << 'EOF'
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
EOF"

REM Set permissions for mongod binary
docker exec %CONTAINER_ID% bash -c "chmod 755 /usr/bin/mongod"

REM Step 5: Export as new image with direct mongod command
docker commit --change="USER mongodb" ^
              --change="CMD [\"mongod\", \"--config\", \"/etc/mongod.conf\"]" ^
              --change="EXPOSE 27017" ^
              --change="VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]" ^
              %CONTAINER_ID% minimal-mongodb:latest

REM Step 6: Cleanup
docker stop %CONTAINER_ID%
docker rm %CONTAINER_ID%

echo Minimal MongoDB image created as 'minimal-mongodb:latest'
echo Image details:
docker images minimal-mongodb:latest