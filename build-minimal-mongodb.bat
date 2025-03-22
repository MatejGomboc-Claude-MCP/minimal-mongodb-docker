@echo off
setlocal enabledelayedexpansion

REM Step 1: Create a temporary container using a minimal Debian base
FOR /F "tokens=*" %%i IN ('docker run -d debian:slim-bullseye sleep infinity') DO SET CONTAINER_ID=%%i

REM Step 2: Install MongoDB and dependencies
docker exec %CONTAINER_ID% bash -c "apt-get update && apt-get install -y wget gnupg && wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add - && echo \"deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main\" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list && apt-get update && apt-get install -y --no-install-recommends mongodb-org-server mongodb-org-shell && apt-get clean"

REM Step 3: Ultra-aggressive cleanup for absolute minimal image
docker exec %CONTAINER_ID% bash -c "apt-get -y --purge autoremove && apt-get -y --purge remove gnupg wget && rm -rf /var/lib/apt /var/lib/dpkg /usr/bin/apt* /usr/bin/dpkg* /sbin/dpkg* /usr/share/dpkg"

REM Identify MongoDB binaries and libraries to preserve
docker exec %CONTAINER_ID% bash -c "mkdir -p /tmp/mongodb-deps && echo '/usr/bin/mongod' > /tmp/mongodb-deps/preserve.txt && echo '/usr/bin/mongosh' >> /tmp/mongodb-deps/preserve.txt && ldd /usr/bin/mongod | grep -o '/[^ ]*' >> /tmp/mongodb-deps/preserve.txt && ldd /usr/bin/mongosh | grep -o '/[^ ]*' >> /tmp/mongodb-deps/preserve.txt"

REM Remove entire unnecessary directory trees
docker exec %CONTAINER_ID% bash -c "rm -rf /usr/share/doc /usr/share/man /usr/share/info && rm -rf /usr/share/locale/* && rm -rf /var/cache/* /var/tmp/* /tmp/{*,.[!.],..?*} 2> /dev/null || true && rm -rf /usr/share/common-licenses && rm -rf /usr/share/pixmaps /usr/share/applications && find /var/log -type f -delete"

REM Keep only UTC and Etc timezones (MongoDB needs these)
docker exec %CONTAINER_ID% bash -c "find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d -not -name UTC -not -name Etc -exec rm -rf {} \;"

REM Strip binaries to reduce size
docker exec %CONTAINER_ID% bash -c "find /usr/bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true && find /usr/sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true && find /bin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true && find /sbin -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true"

REM Remove non-essential binaries (preserving those needed by MongoDB)
docker exec %CONTAINER_ID% bash -c "for f in \$(find /usr/bin /usr/sbin /bin /sbin -type f); do if ! grep -q \"\$f\" /tmp/mongodb-deps/preserve.txt; then rm -f \"\$f\" 2>/dev/null || true; fi; done"

REM Remove all non-MongoDB init scripts and services
docker exec %CONTAINER_ID% bash -c "rm -rf /etc/init.d/* /etc/rc* && rm -rf /etc/cron* /var/spool/cron && rm -rf /etc/logrotate* /etc/ppp /etc/ssh /etc/modprobe.d /etc/modules-load.d"

REM Remove unnecessary language files and libraries
docker exec %CONTAINER_ID% bash -c "rm -rf /usr/lib/python* && rm -rf /usr/share/locale /usr/lib/locale && mkdir -p /usr/share/locale/C.UTF-8"

REM Clean up temporary files
docker exec %CONTAINER_ID% bash -c "rm -rf /tmp/mongodb-deps"

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