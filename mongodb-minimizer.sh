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
  apt-get install -y --no-install-recommends mongodb-org-server mongodb-mongosh
  
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
  apt-get install -y --no-install-recommends coreutils netcat-openbsd

  # Prepare temporary directory structure
  echo "Creating temporary directory..."
  TEMP_DIR="/tmp/mongodb-minimal"
  rm -rf "$TEMP_DIR" 2>/dev/null || true
  mkdir -p "$TEMP_DIR"

  # Create minimization directory structure
  mkdir -p "$TEMP_DIR"/{etc,var/lib/mongodb,var/log/mongodb,usr/share/zoneinfo,tmp,usr/bin}

  # Copy MongoDB binary and strip it
  echo "Copying and stripping MongoDB binary..."
  MONGOD_PATH="$(command -v mongod)"
  if [ -z "$MONGOD_PATH" ]; then
    echo "ERROR: mongod executable not found!"
    exit 1
  fi
  cp "$MONGOD_PATH" "$TEMP_DIR/usr/bin/"
  strip --strip-all "$TEMP_DIR/usr/bin/mongod"

  # Find and copy required libraries to the TEMP_DIR
  echo "Identifying and copying required libraries..."
  for lib in $(ldd "$MONGOD_PATH" | grep -o "/[^ ]*" | sort -u); do
      if [ -f "$lib" ]; then
          lib_dir="$(dirname "$lib")"
          mkdir -p "$TEMP_DIR$lib_dir"
          cp "$lib" "$TEMP_DIR$lib"
          strip --strip-all "$TEMP_DIR$lib" 2>/dev/null || true
      fi
  done

  # Find and copy recursive dependencies to the TEMP_DIR
  echo "Resolving recursive dependencies..."
  for lib in $(find "$TEMP_DIR" -name "*.so*"); do
      for dep in $(ldd "$lib" 2>/dev/null | grep -o "/[^ ]*" | sort -u); do
          if [ -f "$dep" ] && [ ! -f "$TEMP_DIR$dep" ]; then
              dep_dir="$(dirname "$dep")"
              mkdir -p "$TEMP_DIR$dep_dir"
              cp "$dep" "$TEMP_DIR$dep"
              strip --strip-all "$TEMP_DIR$dep" 2>/dev/null || true
          fi
      done
  done

  # Additional dependency handling to catch dynamically loaded libraries
  echo "Checking for dynamically loaded libraries..."
  for so in $(find "$TEMP_DIR" -name "*.so*"); do
    # Extract direct references from the .so file
    for ref in $(objdump -p "$so" 2>/dev/null | grep NEEDED | awk '{print $2}'); do
      # Find the full path of each referenced library
      full_path=$(find /lib /usr/lib -name "$ref" | head -1)
      if [ -n "$full_path" ] && [ ! -f "$TEMP_DIR$full_path" ]; then
        full_path_dir="$(dirname "$full_path")"
        mkdir -p "$TEMP_DIR$full_path_dir"
        cp "$full_path" "$TEMP_DIR$full_path"
        strip --strip-all "$TEMP_DIR$full_path" 2>/dev/null || true
      fi
    done
  done

  # Copy only the absolutely essential timezone data (MongoDB needs this)
  echo "Copying essential timezone data..."
  if [ -d /usr/share/zoneinfo/UTC ]; then
    cp -r /usr/share/zoneinfo/UTC "$TEMP_DIR/usr/share/zoneinfo/"
  else
    echo "WARNING: UTC timezone data not found!"
  fi
  
  if [ -d /usr/share/zoneinfo/Etc ]; then
    cp -r /usr/share/zoneinfo/Etc "$TEMP_DIR/usr/share/zoneinfo/"
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
    pkill -9 -x mongod 2>/dev/null || true
    sleep 2
    if pgrep -x mongod > /dev/null; then
      echo "ERROR: Unable to stop existing MongoDB process!"
      exit 1
    fi
  fi

  # Create keyfile for authentication
  echo "Creating MongoDB keyfile..."
  mkdir -p "$TEMP_DIR/etc/mongodb"
  openssl rand -base64 756 > "$TEMP_DIR/etc/mongodb/keyfile"
  chmod 400 "$TEMP_DIR/etc/mongodb/keyfile"

  # Start MongoDB temporarily to create admin user
  echo "Starting MongoDB to create admin user..."
  mongod --fork --dbpath /var/lib/mongodb --logpath /var/log/mongodb/init.log --bind_ip_all

  # Wait for MongoDB to start properly - check process
  echo "Waiting for MongoDB process to start..."
  sleep 5
  if ! pgrep -x mongod > /dev/null; then
    echo "ERROR: MongoDB process failed to start!"
    cat /var/log/mongodb/init.log
    exit 1
  fi
  
  # Get the MongoDB process ID
  MONGODB_PID=$(pgrep -x mongod)
  echo "MongoDB started with PID: $MONGODB_PID"
  
  # Wait for MongoDB to become available by using netcat to check the port
  echo "Waiting for MongoDB to become available..."
  timeout=30
  started=false
  for ((i=1; i<=timeout; i++)); do
    if nc -z localhost 27017; then
      echo "MongoDB port is open after $i seconds."
      started=true
      break
    fi
    sleep 1
    printf "."
  done
  echo ""
  
  if [ "$started" != "true" ]; then
    echo "ERROR: MongoDB port is not open after $timeout seconds!"
    cat /var/log/mongodb/init.log
    
    # Check if the MongoDB process is still running
    if pgrep -x mongod > /dev/null; then
      echo "Note: MongoDB process is running, but port is not accessible."
      
      # Try to get MongoDB server status directly from log file
      echo "Server log extract:"
      tail -n 20 /var/log/mongodb/init.log
    else
      echo "ERROR: MongoDB process is not running!"
    fi
    
    exit 1
  fi

  # Use mongosh to create admin user
  echo "Creating admin user: ${MONGODB_USERNAME}"
  # Properly escape any special characters in username/password
  ESCAPED_USERNAME=$(printf '%s' "${MONGODB_USERNAME}" | sed 's/"/\\"/g')
  ESCAPED_PASSWORD=$(printf '%s' "${MONGODB_PASSWORD}" | sed 's/"/\\"/g')
  
  # Try to use mongosh if available
  if command -v mongosh > /dev/null; then
    if ! mongosh --host 127.0.0.1 --eval "db = db.getSiblingDB('admin'); db.createUser({user:'${ESCAPED_USERNAME}', pwd:'${ESCAPED_PASSWORD}', roles:[{role:'root', db:'admin'}]})"; then
      echo "ERROR: Failed to create admin user with mongosh!"
      cat /var/log/mongodb/init.log
      exit 1
    fi
  else
    # Fall back to mongod --eval for creating user
    if ! mongod --eval "db = db.getSiblingDB('admin'); db.createUser({user:'${ESCAPED_USERNAME}', pwd:'${ESCAPED_PASSWORD}', roles:[{role:'root', db:'admin'}]})" --dbpath /var/lib/mongodb --port 27017; then
      echo "ERROR: Failed to create admin user!"
      cat /var/log/mongodb/init.log
      exit 1
    fi
  fi

  # Forcefully terminate MongoDB process instead of using shutdown command
  echo "Terminating MongoDB process (PID $MONGODB_PID)..."
  if [ -n "$MONGODB_PID" ] && kill -9 "$MONGODB_PID" 2>/dev/null; then
    echo "MongoDB process terminated."
  else
    echo "WARNING: Could not terminate MongoDB process by PID. Trying pkill..."
    pkill -9 -x mongod || true
  fi
  
  # Wait a moment to ensure the process is fully terminated
  sleep 3
  
  # Final check to ensure MongoDB is stopped
  if pgrep -x mongod > /dev/null; then
    echo "WARNING: MongoDB is still running after termination attempts. This might affect file copying."
  else
    echo "MongoDB process is fully terminated."
  fi
  
  # Copy the pre-initialized data files to ensure admin user exists
  echo "Copying initialized MongoDB data files..."
  mkdir -p "$TEMP_DIR/var/lib/mongodb"
  cp -a /var/lib/mongodb/* "$TEMP_DIR/var/lib/mongodb/" 2>/dev/null || true

  # Create absolute minimal MongoDB configuration with authentication enabled
  echo "Creating MongoDB configuration file..."
  cat > "$TEMP_DIR/etc/mongod.conf" << 'EOF'
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
  echo "mongodb:x:999:999::/var/lib/mongodb:/" > "$TEMP_DIR/etc/passwd"
  echo "mongodb:x:999:" > "$TEMP_DIR/etc/group"

  # Create an empty /etc/nsswitch.conf to avoid getpwnam issues
  echo "Creating nsswitch.conf..."
  echo "passwd: files" > "$TEMP_DIR/etc/nsswitch.conf"
  echo "group: files" >> "$TEMP_DIR/etc/nsswitch.conf"

  # Ensure the log directory exists and has proper permissions
  mkdir -p "$TEMP_DIR/var/log/mongodb"
  chmod 750 "$TEMP_DIR/var/log/mongodb"
  
  # Set proper permissions
  echo "Setting final permissions..."
  chmod 755 "$TEMP_DIR/usr/bin/mongod"
  chmod 400 "$TEMP_DIR/etc/mongodb/keyfile"
  
  # Create a tar archive of all files to preserve permissions
  echo "Creating tar archive of all files..."
  cd "$TEMP_DIR" || { echo "ERROR: Cannot change to temporary directory"; exit 1; }
  tar -cf /tmp/mongodb-minimal.tar .
  
  # Extract the tar archive to the root filesystem
  echo "Extracting files to the root filesystem..."
  cd / || { echo "ERROR: Cannot change to root directory"; exit 1; }
  tar -xf /tmp/mongodb-minimal.tar
  
  # Set final ownership
  echo "Setting final ownership..."
  chown -R 999:999 /var/lib/mongodb /var/log/mongodb /etc/mongodb/keyfile
  
  # Clean up temporary files
  rm -f /tmp/mongodb-minimal.tar
  rm -rf "$TEMP_DIR"
  
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