@echo off
setlocal enabledelayedexpansion

REM Accept parameters with defaults
SET MONGODB_VERSION=%1
IF "%MONGODB_VERSION%"=="" SET MONGODB_VERSION=8.0.6

SET MONGODB_USERNAME=%2
IF "%MONGODB_USERNAME%"=="" SET MONGODB_USERNAME=admin

SET MONGODB_PASSWORD=%3
IF "%MONGODB_PASSWORD%"=="" SET MONGODB_PASSWORD=admin

echo Building minimal MongoDB image with:
echo - MongoDB version: %MONGODB_VERSION%
echo - Admin username: %MONGODB_USERNAME%
echo - Admin password: %MONGODB_PASSWORD%

REM Step 1: Create container
echo Creating temporary container...
FOR /F "tokens=*" %%i IN ('docker run -d debian:bookworm-slim sleep infinity') DO SET CONTAINER_ID=%%i
echo Container created: %CONTAINER_ID%

REM Check if container is running - use a more reliable method
docker inspect --format="{{.State.Running}}" %CONTAINER_ID% | findstr "true" > NUL
IF %ERRORLEVEL% NEQ 0 (
  echo Container failed to start properly!
  docker rm -f %CONTAINER_ID% > NUL 2>&1
  exit /b 1
)

REM Step 2: Copy the minimizer script to the container
echo Copying mongodb-minimizer.sh to container...
docker cp "%~dp0mongodb-minimizer.sh" %CONTAINER_ID%:/tmp/mongodb-minimizer.sh

REM Step 2.1: Fix line endings and ensure script is executable
echo Fixing script line endings and permissions...
docker exec %CONTAINER_ID% bash -c "apt-get update && apt-get install -y dos2unix && dos2unix /tmp/mongodb-minimizer.sh && chmod +x /tmp/mongodb-minimizer.sh"

REM Step 3: Run the installation and minimization process
echo Installing and minimizing MongoDB...
docker exec -e MONGODB_VERSION=%MONGODB_VERSION% ^
           -e MONGODB_USERNAME=%MONGODB_USERNAME% ^
           -e MONGODB_PASSWORD=%MONGODB_PASSWORD% ^
           -e OPERATION=all ^
           %CONTAINER_ID% bash -c "/tmp/mongodb-minimizer.sh"

REM Check for errors
IF %ERRORLEVEL% NEQ 0 (
  echo MongoDB installation or minimization failed!
  docker stop %CONTAINER_ID%
  docker rm %CONTAINER_ID%
  exit /b 1
)

REM Step 4: Extract Docker commit options
echo Getting Docker commit options...
SET TEMP_COMMIT_FILE=%TEMP%\mongodb_commit_options.txt
docker exec -e OPERATION=commit-options %CONTAINER_ID% bash -c "/tmp/mongodb-minimizer.sh" > %TEMP_COMMIT_FILE%

REM Step 5: Commit container with extracted options
echo Creating minimal MongoDB image...
SET COMMIT_CMD=docker commit
FOR /F "tokens=*" %%a IN ('findstr /v "===" %TEMP_COMMIT_FILE% ^| findstr /v "^$"') DO (
  SET COMMIT_CMD=!COMMIT_CMD! %%a
)
SET COMMIT_CMD=!COMMIT_CMD! %CONTAINER_ID% minimal-mongodb:latest
%COMMIT_CMD%

IF %ERRORLEVEL% NEQ 0 (
  echo Docker commit failed!
  docker stop %CONTAINER_ID%
  docker rm %CONTAINER_ID%
  del %TEMP_COMMIT_FILE%
  exit /b 1
)

REM Step 6: Clean up
del %TEMP_COMMIT_FILE%
docker stop %CONTAINER_ID%
docker rm %CONTAINER_ID%

echo.
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
