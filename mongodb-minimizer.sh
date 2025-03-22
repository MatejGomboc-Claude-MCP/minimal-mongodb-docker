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
  # FIXED: Changed to create the parent zoneinfo directory only, not UTC and Etc subdirectories
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
    authorization: enabled
EOF

  # Create passwd entry for MongoDB user (uid 999 is common for mongodb)
  echo "mongodb:x:999:999::/var/lib/mongodb:/" > /mongodb-minimal/etc/passwd
  echo "mongodb:x:999:" > /mongodb-minimal/etc/group

  # Create an empty /etc/nsswitch.conf to avoid getpwnam issues
  echo "passwd: files" > /mongodb-minimal/etc/nsswitch.conf
  echo "group: files" >> /mongodb-minimal/etc/nsswitch.conf

  # FIXED: Copy essential binaries for post-cleanup operations 
  mkdir -p /mongodb-minimal/bin
  cp /bin/mv /mongodb-minimal/bin/
  cp /bin/cp /mongodb-minimal/bin/
  cp /bin/rm /mongodb-minimal/bin/
  cp /bin/mkdir /mongodb-minimal/bin/
  cp /bin/chmod /mongodb-minimal/bin/
  cp /bin/chown /mongodb-minimal/bin/
  cp /bin/touch /mongodb-minimal/bin/
  
  # FIXED: Create a small script to handle the cleanup and restoration
  cat > /mongodb-minimal/cleanup.sh << 'EOF'
#!/bin/sh
# Preserve PATH to ensure we can find our saved commands
PATH=/mongodb-minimal/bin:$PATH
export PATH

# Move minimal contents to root while preserving our critical binaries
find /mongodb-minimal -mindepth 1 -maxdepth 1 -not -name bin | while read dir; do
  mv "$dir"/* /$(basename "$dir")/
done

# Now clean up the temporary directory
rm -rf /mongodb-minimal
EOF

  # Make the cleanup script executable
  chmod +x /mongodb-minimal/cleanup.sh

  # FIXED: Use the cleanup script instead of directly running rm and mv
  /mongodb-minimal/cleanup.sh

  # Set proper permissions
  chmod 755 /usr/bin/mongod
  mkdir -p /var/lib/mongodb /var/log/mongodb
  chown -R 999:999 /var/lib/mongodb /var/log/mongodb

  # Start MongoDB temporarily without auth to create the admin user
  mongod --fork --logpath /var/log/mongodb/init.log --dbpath /var/lib/mongodb

  # Verify MongoDB started correctly
  if ! pgrep -x mongod > /dev/null; then
    echo 'MongoDB failed to start!'
    cat /var/log/mongodb/init.log
    exit 1
  fi

  # Create a default admin user with supplied credentials
  # Users should change this password after first login
  mongod --eval "db = db.getSiblingDB(\"admin\"); db.createUser({user:\"${MONGODB_USERNAME}\", pwd:\"${MONGODB_PASSWORD}\", roles:[{role:\"root\", db:\"admin\"}]})"

  # Stop the temporary MongoDB instance
  mongod --shutdown

  # Create a file indicating this is a pre-configured instance
  touch /var/lib/mongodb/.preconfigured
  
  echo "MongoDB minimization completed successfully."
}

# Function to print Docker commit command options
print_docker_commit_options() {
  echo "===DOCKER_COMMIT_OPTIONS_START==="
  echo "--change='USER mongodb'"
  echo "--change='CMD [\"mongod\", \"--config\", \"/etc/mongod.conf\"]'"
  echo "--change='EXPOSE 27017'"
  echo "--change='VOLUME [\"/var/lib/mongodb\", \"/var/log/mongodb\"]'"
  echo "--change='HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD [ \"mongod\", \"--eval\", \"db.adminCommand(\\'ping\\')\", \"--quiet\" ]'"
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