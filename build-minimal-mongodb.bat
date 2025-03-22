@echo off
setlocal enabledelayedexpansion

REM Accept parameters with defaults
SET MONGODB_VERSION=%1
IF "%MONGODB_VERSION%"=="" SET MONGODB_VERSION=6.0

SET MONGODB_USERNAME=%2
IF "%MONGODB_USERNAME%"=="" SET MONGODB_USERNAME=admin

SET MONGODB_PASSWORD=%3
IF "%MONGODB_PASSWORD%"=="" SET MONGODB_PASSWORD=mongoadmin

echo Building minimal MongoDB image with:
echo - MongoDB version: %MONGODB_VERSION%
echo - Admin username: %MONGODB_USERNAME%
echo - Admin password: %MONGODB_PASSWORD%

REM Create a temporary script file to avoid escaping issues
SET TEMP_SCRIPT=%TEMP%\mongodb_build.sh
(
echo #!/bin/bash
echo set -e
echo
echo # Test MongoDB installation
echo if ! mongod --version; then
echo   echo 'MongoDB installation failed!'
echo   exit 1
echo fi
echo
echo # Create minimization directory structure
echo mkdir -p /mongodb-minimal/{etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo/UTC,usr/share/zoneinfo/Etc,tmp,usr/bin}
echo
echo # Copy MongoDB binary and strip it
echo cp /usr/bin/mongod /mongodb-minimal/usr/bin/
echo strip --strip-all /mongodb-minimal/usr/bin/mongod
echo
echo # Find and copy required libraries
echo for lib in $^(ldd /usr/bin/mongod ^| grep -o "/[^ ]*" ^| sort -u^); do
echo     if [ -f "$lib" ]; then
echo         mkdir -p "/mongodb-minimal$^(dirname "$lib"^)"
echo         cp "$lib" "/mongodb-minimal$lib"
echo         strip --strip-all "/mongodb-minimal$lib"
echo     fi
echo done
echo
echo # Find and copy recursive dependencies
echo for lib in $^(find /mongodb-minimal -name "*.so*"^); do
echo     for dep in $^(ldd $lib 2^>/dev/null ^| grep -o "/[^ ]*" ^| sort -u^); do
echo         if [ -f "$dep" ] ^&^& [ ! -f "/mongodb-minimal$dep" ]; then
echo             mkdir -p "/mongodb-minimal$^(dirname "$dep"^)"
echo             cp "$dep" "/mongodb-minimal$dep"
echo             strip --strip-all "/mongodb-minimal$dep"
echo         fi
echo     done
echo done
echo
echo # Additional dependency handling
echo for so in $^(find /mongodb-minimal -name "*.so*"^); do
echo   for ref in $^(objdump -p "$so" ^| grep NEEDED ^| awk '{print $2}'^); do
echo     full_path=$^(find /lib /usr/lib -name "$ref" ^| head -1^)
echo     if [ -n "$full_path" ] ^&^& [ ! -f "/mongodb-minimal$full_path" ]; then
echo       mkdir -p "/mongodb-minimal$^(dirname "$full_path"^)"
echo       cp "$full_path" "/mongodb-minimal$full_path"
echo       strip --strip-all "/mongodb-minimal$full_path"
echo     fi
echo   done
echo done
echo
echo # Copy timezone data
echo cp -r /usr/share/zoneinfo/UTC /mongodb-minimal/usr/share/zoneinfo/
echo cp -r /usr/share/zoneinfo/Etc /mongodb-minimal/usr/share/zoneinfo/
echo
echo # Create MongoDB configuration
echo cat ^> /mongodb-minimal/etc/mongod.conf ^<^< EOF
echo storage:
echo     dbPath: /var/lib/mongodb
echo     journal:
echo         enabled: true
echo systemLog:
echo     destination: file
echo     path: /var/log/mongodb/mongod.log
echo     logAppend: true
echo net:
echo     port: 27017
echo     bindIp: 0.0.0.0
echo processManagement:
echo     timeZoneInfo: /usr/share/zoneinfo
echo     fork: false
echo security:
echo     authorization: enabled
echo EOF
echo
echo # Create user entries
echo echo "mongodb:x:999:999::/var/lib/mongodb:/" ^> /mongodb-minimal/etc/passwd
echo echo "mongodb:x:999:" ^> /mongodb-minimal/etc/group
echo echo "passwd: files" ^> /mongodb-minimal/etc/nsswitch.conf
echo echo "group: files" ^>^> /mongodb-minimal/etc/nsswitch.conf
echo
echo # Create JavaScript initialization file with user creation logic
echo cat ^> /mongodb-minimal/var/lib/mongodb/init.js ^<^< EOF
echo db = db.getSiblingDB^(\"admin\"^);
echo db.createUser^({
echo   user: \"${MONGODB_USERNAME}\",
echo   pwd: \"${MONGODB_PASSWORD}\",
echo   roles: [{role: \"root\", db: \"admin\"}]
echo }^);
echo EOF
echo
echo # NUKE EVERYTHING, then restore only our minimal copy
echo rm -rf /* 2^>/dev/null ^|^| true
echo mv /mongodb-minimal/* /
echo rm -rf /mongodb-minimal
echo
echo # Set proper permissions
echo chmod 755 /usr/bin/mongod
echo mkdir -p /var/lib/mongodb /var/log/mongodb
echo chown -R 999:999 /var/lib/mongodb /var/log/mongodb
echo chown 999:999 /var/lib/mongodb/init.js
echo
echo # Create a flag file that will trigger initialization on first container start
echo touch /var/lib/mongodb/.initialized
echo chown 999:999 /var/lib/mongodb/.initialized
) > %TEMP_SCRIPT%

REM Step 1: Create container
FOR /F "tokens=*" %%i IN ('docker run -d debian:slim-bullseye sleep infinity') DO SET CONTAINER_ID=%%i

echo Container created: %CONTAINER_ID%

REM Step 2: Install MongoDB dependencies
echo Installing MongoDB %MONGODB_VERSION% and dependencies...
docker exec %CONTAINER_ID% bash -c "apt-get update && apt-get install -y wget gnupg binutils && wget -qO - https://www.mongodb.org/static/pgp/server-%MONGODB_VERSION%.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/mongodb-%MONGODB_VERSION%.gpg && echo \"deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/%MONGODB_VERSION% main\" | tee /etc/apt/sources.list.d/mongodb-org-%MONGODB_VERSION%.list && apt-get update && apt-get install -y --no-install-recommends mongodb-org-server && apt-get clean"

REM Step 3: Perform minimization
echo Performing MongoDB minimization...

REM Copy and execute the build script
docker cp %TEMP_SCRIPT% %CONTAINER_ID%:/tmp/build_script.sh

REM Replace variables in the script
docker exec %CONTAINER_ID% bash -c "sed -i 's/\${MONGODB_USERNAME}/%MONGODB_USERNAME%/g' /tmp/build_script.sh"
docker exec %CONTAINER_ID% bash -c "sed -i 's/\${MONGODB_PASSWORD}/%MONGODB_PASSWORD%/g' /tmp/build_script.sh"

REM Execute the script
docker exec %CONTAINER_ID% bash -c "chmod +x /tmp/build_script.sh && /tmp/build_script.sh"

REM Cleanup temp file
del %TEMP_SCRIPT%

REM Step 4: Export as new image with init logic and healthcheck
docker commit --change="USER mongodb" ^
    --change="CMD [\"sh\", \"-c\", \"if [ -f /var/lib/mongodb/.initialized ] && [ ! -f /var/lib/mongodb/.completed ]; then mongod --fork --logpath /var/log/mongodb/init.log --dbpath /var/lib/mongodb; mongod --eval \\\"load('/var/lib/mongodb/init.js')\\\"; mongod --shutdown; rm /var/lib/mongodb/init.js; touch /var/lib/mongodb/.completed; fi; exec mongod --config /etc/mongod.conf\"]" ^
    --change="EXPOSE 27017" ^
    --change="VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]" ^
    --change="HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD [ \"mongod\", \"--eval\", \"db.adminCommand('ping')\", \"--quiet\" ]" ^
    %CONTAINER_ID% minimal-mongodb:latest

REM Step 5: Cleanup
docker stop %CONTAINER_ID%
docker rm %CONTAINER_ID%

echo Minimal MongoDB image created as 'minimal-mongodb:latest'
echo Image details:
docker images minimal-mongodb:latest
echo.
echo MongoDB credentials:
echo Username: %MONGODB_USERNAME%
echo Password: %MONGODB_PASSWORD%
echo.
echo IMPORTANT: Change the default password after first login!
echo Usage example: docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest
