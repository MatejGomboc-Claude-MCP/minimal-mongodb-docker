#!/bin/bash
set -e

# Ensure errors are properly reported
handle_minimizer_error() {
  local error_code=$?
  echo "Error: Minimizer script failed with exit code $error_code"
  echo "Failed at step: $1"
  exit $error_code
}

# Set trap to catch errors
trap 'handle_minimizer_error "${BASH_COMMAND}"' ERR

# These variables will be passed when running the script
MONGODB_VERSION="${MONGODB_VERSION:-8.0.6}"
MONGODB_USERNAME="${MONGODB_USERNAME:-admin}"
MONGODB_PASSWORD="${MONGODB_PASSWORD:-admin}"
OPERATION="${OPERATION:-all}"

# Function to install MongoDB
install_mongodb() {
  echo "Installing MongoDB ${MONGODB_VERSION}..."
  
  # Extract the major.minor version for the repository
  MONGODB_MAJOR_MINOR="$(echo "${MONGODB_VERSION}" | cut -d. -f1,2)"
  
  # Update package information
  apt-get update
  
  # Install required packages
  apt-get install -y wget gnupg binutils curl procps openssl
  
  # Import MongoDB GPG key
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGODB_MAJOR_MINOR}.asc" | \
    gpg -o "/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR_MINOR}.gpg" --dearmor
  
  # Add MongoDB repository
  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR_MINOR}.gpg] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGODB_MAJOR_MINOR} main" | \
    tee "/etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR_MINOR}.list"
  
  # Update package list with MongoDB repository
  apt-get update
  
  # Install MongoDB server
  apt-get install -y --no-install-recommends mongodb-org-server
  
  # Clean up package cache
  apt-get clean
  
  # Verify MongoDB installation
  if ! command -v mongod > /dev/null; then
    echo "MongoDB installation failed - mongod command not found!"
    exit 1
  fi
  
  echo "MongoDB ${MONGODB_VERSION} installed successfully."
}

# Function to perform minimization
minimize_mongodb() {
  echo "Starting MongoDB minimization process..."
  
  # Test MongoDB installation
  if ! mongod --version; then
    echo 'MongoDB installation failed!'
    exit 1
  fi

  # Install essential packages to ensure they are available
  apt-get install -y --no-install-recommends coreutils

  # Create minimization directory structure
  mkdir -p /mongodb-minimal/{etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo,tmp,usr/bin}

  # Copy MongoDB binary and strip it
  echo "Copying and stripping MongoDB binary..."
  MONGOD_PATH="$(command -v mongod)"
  if [ -z "$MONGOD_PATH" ]; then
    echo "ERROR: mongod executable not found!"
    exit 1
  fi
  cp "$MONGOD_PATH" /mongodb-minimal/usr/bin/
  strip --strip-all /mongodb-minimal/usr/bin/mongod

  # Find and copy required libraries
  echo "Identifying and copying required libraries..."
  for lib in $(ldd "$MONGOD_PATH" | grep -o "/[^ ]*" | sort -u); do
      if [ -f "$lib" ]; then
          mkdir -p "/mongodb-minimal$(dirname "$lib")"
          cp "$lib" "/mongodb-minimal$lib"
          strip --strip-all "/mongodb-minimal$lib" 2>/dev/null || true
      fi
  done

  # Find and copy recursive dependencies
  echo "Resolving recursive dependencies..."
  for lib in $(find /mongodb-minimal -name "*.so*"); do
      for dep in $(ldd "$lib" 2>/dev/null | grep -o "/[^ ]*" | sort -u); do
          if [ -f "$dep" ] && [ ! -f "/mongodb-minimal$dep" ]; then
              mkdir -p "/mongodb-minimal$(dirname "$dep")"
              cp "$dep" "/mongodb-minimal$dep"
              strip --strip-all "/mongodb-minimal$dep" 2>/dev/null || true
          fi
      done
  done

  # Additional dependency handling to catch dynamically loaded libraries
  echo "Checking for dynamically loaded libraries..."
  for so in $(find /mongodb-minimal -name "*.so*"); do
    # Extract direct references from the .so file
    for ref in $(objdump -p "$so" 2>/dev/null | grep NEEDED | awk '{print $2}'); do
      # Find the full path of each referenced library
      full_path=$(find /lib /usr/lib -name "$ref" | head -1)
      if [ -n "$full_path" ] && [ ! -f "/mongodb-minimal$full_path" ]; then
        mkdir -p "/mongodb-minimal$(dirname "$full_path")"
        cp "$full_path" "/mongodb-minimal$full_path"
        strip --strip-all "/mongodb-minimal$full_path" 2>/dev/null || true
      fi
    done
  done

  # Copy only the absolutely essential timezone data (MongoDB needs this)
  echo "Copying essential timezone data..."
  if [ -d /usr/share/zoneinfo/UTC ]; then
    cp -r /usr/share/zoneinfo/UTC /mongodb-minimal/usr/share/zoneinfo/
  else
    echo "WARNING: UTC timezone data not found!"
  fi
  
  if [ -d /usr/share/zoneinfo/Etc ]; then
    cp -r /usr/share/zoneinfo/Etc /mongodb-minimal/usr/share/zoneinfo/
  else
    echo "WARNING: Etc timezone data not found!"
  fi

  # Prepare data directory
  echo "Preparing MongoDB data directory..."
  rm -rf /var/lib/mongodb/* 2>/dev/null || true
  mkdir -p /var/lib/mongodb
  mkdir -p /var/log/mongodb
  chmod 750 /var/lib/mongodb
  chmod 750 /var/log/mongodb

  # Check for existing MongoDB process before starting
  if pgrep -x mongod > /dev/null; then
    echo "WARNING: MongoDB is already running. Stopping it first..."
    if ! mongod --dbpath /var/lib/mongodb --shutdown; then
      echo "WARNING: Failed to stop existing MongoDB process gracefully, trying pkill..."
      pkill -x mongod 2>/dev/null || true
      sleep 2
      if pgrep -x mongod > /dev/null; then
        echo "ERROR: Unable to stop existing MongoDB process!"
        exit 1
      fi
    fi
  fi

  # Start MongoDB temporarily to create admin user
  echo "Starting MongoDB to create admin user..."
  if ! mongod --fork --logpath /var/log/mongodb/init.log --dbpath /var/lib/mongodb; then
    echo "ERROR: Failed to start MongoDB!"
    cat /var/log/mongodb/init.log
    exit 1
  fi

  # Wait for MongoDB to start properly
  echo "Waiting for MongoDB to start..."
  timeout=30
  started=false
  for ((i=1; i<=timeout; i++)); do
    if mongod --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
      echo "MongoDB started successfully after $i seconds."
      started=true
      break
    fi
    sleep 1
    printf "."
  done
  echo ""
  
  if [ "$started" != "true" ]; then
    echo "ERROR: MongoDB failed to start after $timeout seconds!"
    cat /var/log/mongodb/init.log
    exit 1
  fi

  # Create a default admin user with supplied credentials during build
  echo "Creating admin user: ${MONGODB_USERNAME}"
  # Properly escape any special characters in username/password
  ESCAPED_USERNAME=$(printf '%s' "${MONGODB_USERNAME}" | sed 's/"/\\"/g')
  ESCAPED_PASSWORD=$(printf '%s' "${MONGODB_PASSWORD}" | sed 's/"/\\"/g')
  
  if ! mongod --eval "db = db.getSiblingDB(\"admin\"); db.createUser({user:\"${ESCAPED_USERNAME}\", pwd:\"${ESCAPED_PASSWORD}\", roles:[{role:\"root\", db:\"admin\"}]})"; then
    echo "ERROR: Failed to create admin user!"
    cat /var/log/mongodb/init.log
    exit 1
  fi

  # Create keyfile for authentication
  echo "Creating MongoDB keyfile..."
  mkdir -p /mongodb-minimal/etc/mongodb
  openssl rand -base64 756 > /mongodb-minimal/etc/mongodb/keyfile
  chmod 400 /mongodb-minimal/etc/mongodb/keyfile

  # Stop MongoDB and copy the initialized data files
  echo "Stopping MongoDB..."
  if ! mongod --dbpath /var/lib/mongodb --shutdown; then
    echo "WARNING: Problem shutting down MongoDB gracefully."
  fi
  
  # Ensure MongoDB has completely stopped
  echo "Waiting for MongoDB process to terminate..."
  timeout=30
  stopped=false
  for ((i=1; i<=timeout; i++)); do
    if ! pgrep -x mongod > /dev/null; then
      echo "MongoDB stopped successfully after $i seconds."
      stopped=true
      break
    fi
    sleep 1
    printf "."
  done
  echo ""
  
  # Forcefully terminate if still running
  if [ "$stopped" != "true" ]; then
    echo "Warning: MongoDB did not shut down gracefully after $timeout seconds, terminating process..."
    pkill -9 mongod 2>/dev/null || true
    sleep 2
    
    # Final check to ensure it's really stopped
    if pgrep -x mongod > /dev/null; then
      echo "ERROR: Unable to stop MongoDB process!"
      exit 1
    fi
  fi
  
  # Copy the pre-initialized data files to ensure admin user exists
  echo "Copying initialized MongoDB data files..."
  mkdir -p /mongodb-minimal/var/lib/mongodb
  if ! cp -a /var/lib/mongodb/* /mongodb-minimal/var/lib/mongodb/ 2>/dev/null; then
    echo "WARNING: Some MongoDB data files could not be copied. This might be normal if the database is empty."
  fi

  # Create absolute minimal MongoDB configuration with authentication enabled
  echo "Creating MongoDB configuration file..."
  cat > /mongodb-minimal/etc/mongod.conf << 'EOF'
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
EOF

  # Create passwd entry for MongoDB user (uid 999 is common for mongodb)
  echo "Creating user entries..."
  echo "mongodb:x:999:999::/var/lib/mongodb:/" > /mongodb-minimal/etc/passwd
  echo "mongodb:x:999:" > /mongodb-minimal/etc/group

  # Create an empty /etc/nsswitch.conf to avoid getpwnam issues
  echo "Creating nsswitch.conf..."
  echo "passwd: files" > /mongodb-minimal/etc/nsswitch.conf
  echo "group: files" >> /mongodb-minimal/etc/nsswitch.conf

  # Ensure the log directory exists and has proper permissions
  mkdir -p /mongodb-minimal/var/log/mongodb
  chmod 750 /mongodb-minimal/var/log/mongodb
  
  # Directly move files from minimal directory to root
  echo "Moving minimal files to root filesystem..."
  cd /mongodb-minimal || { echo "ERROR: Cannot change to directory /mongodb-minimal"; exit 1; }

  # Save current IFS, set to newline only to handle filenames with spaces
  OLDIFS="$IFS"
  IFS=$'\n'
  
  # For each directory under /mongodb-minimal, copy its contents to the root
  # Using a more reliable method for handling spaces in filenames
  find . -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d $'\0' dir; do
    dir="${dir#./}"
    # Ensure target directory exists
    mkdir -p "/$dir"
    
    # Handle potential spaces in filenames with null-terminated strings
    find "./$dir" -mindepth 1 -print0 | while IFS= read -r -d $'\0' item; do
      target_path="/${item#./}"
      target_dir="$(dirname "$target_path")"
      mkdir -p "$target_dir"
      if ! cp -a "$item" "$target_path" 2>/dev/null; then
        echo "WARNING: Failed to copy $item to $target_path"
      fi
    done
  done
  
  # Move any files in the root of /mongodb-minimal
  find . -maxdepth 1 -type f -print0 | while IFS= read -r -d $'\0' file; do
    file="${file#./}"
    if ! cp -a "$file" "/$file" 2>/dev/null; then
      echo "WARNING: Failed to copy $file to /$file"
    fi
  done
  
  # Restore original IFS
  IFS="$OLDIFS"
  
  # Return to root and remove the temporary directory
  cd / || { echo "ERROR: Cannot change to root directory"; exit 1; }
  rm -rf /mongodb-minimal

  # Set proper permissions
  echo "Setting final permissions..."
  chmod 755 /usr/bin/mongod
  chmod 400 /etc/mongodb/keyfile
  chown -R 999:999 /var/lib/mongodb /var/log/mongodb /etc/mongodb/keyfile
  
  echo "MongoDB minimization completed successfully."
  
  # Verify the installation is functional
  echo "Verifying the minimized MongoDB installation..."
  if [ -x "/usr/bin/mongod" ]; then
    echo "MongoDB binary exists and is executable."
  else
    echo "ERROR: MongoDB binary is missing or not executable!"
    exit 1
  fi
  
  # Check for critical files
  if [ ! -f "/etc/mongod.conf" ]; then
    echo "ERROR: MongoDB configuration file is missing!"
    exit 1
  fi
  
  if [ ! -f "/etc/mongodb/keyfile" ]; then
    echo "ERROR: MongoDB keyfile is missing!"
    exit 1
  fi
  
  # Verify library dependencies can be resolved
  echo "Checking library dependencies..."
  if ! ldd /usr/bin/mongod >/dev/null 2>&1; then
    echo "ERROR: MongoDB binary has unresolved dependencies!"
    ldd /usr/bin/mongod
    exit 1
  fi
  
  echo "Verification complete. Minimized MongoDB is ready to be packaged."
}

# Function to print Docker commit command options
print_docker_commit_options() {
  echo "===DOCKER_COMMIT_OPTIONS_START==="
  echo "--change='USER mongodb'"
  echo "--change='CMD [\"mongod\", \"--config\", \"/etc/mongod.conf\"]'"
  echo "--change='EXPOSE 27017'"
  echo "--change='VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]'"
  echo "--change='HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD [ \"mongod\", \"--eval\", \"db.adminCommand(\\\'ping\\\')\", \"--quiet\" ]'"
  echo "===DOCKER_COMMIT_OPTIONS_END==="
}

# Main logic based on operation
case "$OPERATION" in
  "install")
    install_mongodb
    ;;
  "minimize")
    minimize_mongodb
    ;;
  "commit-options")
    print_docker_commit_options
    ;;
  "all")
    install_mongodb
    minimize_mongodb
    print_docker_commit_options
    ;;
  *)
    echo "Unknown operation: ${OPERATION}"
    echo "Valid operations: install, minimize, commit-options, all"
    exit 1
    ;;
esac