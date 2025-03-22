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
MONGODB_VERSION="${MONGODB_VERSION}"
MONGODB_USERNAME="${MONGODB_USERNAME}"
MONGODB_PASSWORD="${MONGODB_PASSWORD}"
OPERATION="${OPERATION}"

# Function to install MongoDB
install_mongodb() {
  echo "Installing MongoDB ${MONGODB_VERSION}..."
  
  # Extract the major.minor version for the repository
  MONGODB_MAJOR_MINOR=$(echo ${MONGODB_VERSION} | cut -d. -f1,2)
  
  # Update package information
  apt-get update
  
  # Install required packages
  apt-get install -y wget gnupg binutils curl
  
  # Import MongoDB GPG key
  curl -fsSL https://www.mongodb.org/static/pgp/server-${MONGODB_MAJOR_MINOR}.asc | \
    gpg -o /usr/share/keyrings/mongodb-server-${MONGODB_MAJOR_MINOR}.gpg --dearmor
  
  # Add MongoDB repository
  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR_MINOR}.gpg] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/${MONGODB_MAJOR_MINOR} main" | \
    tee /etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR_MINOR}.list
  
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
  cp /usr/bin/mongod /mongodb-minimal/usr/bin/
  strip --strip-all /mongodb-minimal/usr/bin/mongod

  # Find and copy required libraries
  for lib in $(ldd /usr/bin/mongod | grep -o "/[^ ]*" | sort -u); do
      if [ -f "$lib" ]; then
          mkdir -p "/mongodb-minimal$(dirname "$lib")"
          cp "$lib" "/mongodb-minimal$lib"
          strip --strip-all "/mongodb-minimal$lib"
      fi
  done

  # Find and copy recursive dependencies
  for lib in $(find /mongodb-minimal -name "*.so*"); do
      for dep in $(ldd $lib 2>/dev/null | grep -o "/[^ ]*" | sort -u); do
          if [ -f "$dep" ] && [ ! -f "/mongodb-minimal$dep" ]; then
              mkdir -p "/mongodb-minimal$(dirname "$dep")"
              cp "$dep" "/mongodb-minimal$dep"
              strip --strip-all "/mongodb-minimal$dep"
          fi
      done
  done

  # Additional dependency handling to catch dynamically loaded libraries
  for so in $(find /mongodb-minimal -name "*.so*"); do
    # Extract direct references from the .so file
    for ref in $(objdump -p "$so" | grep NEEDED | awk '{print $2}'); do
      # Find the full path of each referenced library
      full_path=$(find /lib /usr/lib -name "$ref" | head -1)
      if [ -n "$full_path" ] && [ ! -f "/mongodb-minimal$full_path" ]; then
        mkdir -p "/mongodb-minimal$(dirname "$full_path")"
        cp "$full_path" "/mongodb-minimal$full_path"
        strip --strip-all "/mongodb-minimal$full_path"
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
    authorization: disabled
EOF

  # Create passwd entry for MongoDB user (uid 999 is common for mongodb)
  echo "mongodb:x:999:999::/var/lib/mongodb:/" > /mongodb-minimal/etc/passwd
  echo "mongodb:x:999:" > /mongodb-minimal/etc/group

  # Create an empty /etc/nsswitch.conf to avoid getpwnam issues
  echo "passwd: files" > /mongodb-minimal/etc/nsswitch.conf
  echo "group: files" >> /mongodb-minimal/etc/nsswitch.conf

  # Instead of running MongoDB to create a user during build,
  # we'll create an initialization script that will run on first container start
  
  # Create entrypoint script to initialize MongoDB on first run
  mkdir -p /mongodb-minimal/usr/local/bin
  cat > /mongodb-minimal/usr/local/bin/docker-entrypoint.sh << 'EOF'
#!/bin/sh
set -e

# This script runs as mongodb user (uid 999)

# Check if this is first run (no .initialized file)
if [ ! -f /var/lib/mongodb/.initialized ]; then
    echo "Initializing MongoDB for first run..."
    
    # Start mongod without auth for initial setup
    mongod --dbpath /var/lib/mongodb --logpath /var/log/mongodb/init.log --fork --bind_ip 127.0.0.1
    
    # Wait for MongoDB to start
    for i in {1..30}; do
        if mongod --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            break
        fi
        echo "Waiting for MongoDB to start... ($i/30)"
        sleep 1
    done
    
    # Create admin user
    mongod --eval "db = db.getSiblingDB('admin'); db.createUser({user:'MONGODB_USERNAME_PLACEHOLDER', pwd:'MONGODB_PASSWORD_PLACEHOLDER', roles:[{role:'root', db:'admin'}]})"
    
    # Shut down MongoDB
    mongod --dbpath /var/lib/mongodb --shutdown
    
    # Create initialized marker
    touch /var/lib/mongodb/.initialized
    echo "MongoDB initialization complete."
fi

# Start MongoDB with regular configuration
exec mongod --config /etc/mongod.conf
EOF

  # Replace placeholders with actual values
  sed -i "s/MONGODB_USERNAME_PLACEHOLDER/${MONGODB_USERNAME}/g" /mongodb-minimal/usr/local/bin/docker-entrypoint.sh
  sed -i "s/MONGODB_PASSWORD_PLACEHOLDER/${MONGODB_PASSWORD}/g" /mongodb-minimal/usr/local/bin/docker-entrypoint.sh
  
  # Make the entrypoint script executable
  chmod 755 /mongodb-minimal/usr/local/bin/docker-entrypoint.sh

  # Directly move files from minimal directory to root
  # This approach eliminates the need for extra binaries
  echo "Moving minimal files to root directly..."
  cd /mongodb-minimal
  
  # For each directory under /mongodb-minimal, copy its contents to the root
  for dir in $(find . -mindepth 1 -maxdepth 1 -type d | cut -c 3-); do
    # Ensure target directory exists
    mkdir -p "/$dir"
    
    # Move contents
    cp -a "$dir"/* "/$dir/" 2>/dev/null || true
  done
  
  # Move any files in the root of /mongodb-minimal
  for file in $(find . -maxdepth 1 -type f | cut -c 3-); do
    cp -a "$file" "/$file" 2>/dev/null || true
  done
  
  # Return to root and remove the temporary directory
  cd /
  rm -rf /mongodb-minimal

  # Set proper permissions
  chmod 755 /usr/bin/mongod
  mkdir -p /var/lib/mongodb /var/log/mongodb
  chown -R 999:999 /var/lib/mongodb /var/log/mongodb
  
  echo "MongoDB minimization completed successfully."
}

# Function to print Docker commit command options
print_docker_commit_options() {
  echo "===DOCKER_COMMIT_OPTIONS_START==="
  echo "--change='USER mongodb'"
  echo "--change='ENTRYPOINT [\"/usr/local/bin/docker-entrypoint.sh\"]'"
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