# Ultra-Minimal MongoDB Docker Image

This repository contains scripts to create an extremely minimalist MongoDB Docker image using standard Debian paths. The approach focuses on creating the absolute smallest possible functional MongoDB image while maintaining compatibility with MongoDB client tools like Compass.

## Features

- Creates a ultra-minimal MongoDB container based on Debian slim
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Aggressively removes all unnecessary components to minimize image size
- Avoids using Dockerfile for a more streamlined build process

## Ultra-Aggressive Minimization Steps

The scripts use several advanced techniques to create a truly minimal image:

1. **Intelligent Binary Preservation**:
   - Identifies all MongoDB binaries (mongod, mongosh)
   - Uses `ldd` to detect required shared libraries
   - Preserves only these essential files
   - Removes all other binaries from the system

2. **Package Management Removal**:
   - Completely removes apt and dpkg after MongoDB installation
   - Removes all package management directories and files

3. **Unnecessary Directory Removal**:
   - Removes documentation, man pages, and locale data
   - Removes all log files except MongoDB's log directory
   - Keeps only UTC and Etc timezone data (required by MongoDB)
   - Removes unnecessary system utilities and shell scripts

4. **Service Cleanup**:
   - Removes all init scripts and boot services
   - Removes cron, logrotate, and other scheduled task mechanisms
   - Removes PPP, SSH and other network service configurations

5. **Binary Size Reduction**:
   - Strips all binaries to remove debug symbols
   - Removes all Python files (MongoDB is C++)
   - Removes all non-C locales

These techniques create an image that is typically 70-80% smaller than standard MongoDB images while maintaining full functionality.

## Scripts

Two scripts are provided:

1. `build-minimal-mongodb.sh` - For Linux/macOS users
2. `build-minimal-mongodb.bat` - For Windows users

Both scripts produce identical Docker images.

## Usage

### Linux/macOS

```bash
# Make the script executable
chmod +x build-minimal-mongodb.sh

# Run the script
./build-minimal-mongodb.sh
```

### Windows

```batch
# Run the script
build-minimal-mongodb.bat
```

## Running the MongoDB Container

After building the image, you can run it with:

```bash
docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest
```

### Initial Setup

On first run, you may need to set up a MongoDB user for authentication:

```bash
# Run MongoDB temporarily without authentication
docker run -d -p 27017:27017 --name mongodb-setup minimal-mongodb:latest mongod --config /etc/mongod.conf --auth false

# Connect to the MongoDB instance
docker exec -it mongodb-setup mongosh

# In the MongoDB shell, create an admin user
use admin
db.createUser({
  user: "mongoAdmin",
  pwd: "securePassword",  # Change this!
  roles: [ { role: "userAdminAnyDatabase", db: "admin" }, "readWriteAnyDatabase" ]
})

# Exit and clean up
exit
docker stop mongodb-setup
docker rm mongodb-setup

# Now run with authentication enabled
docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest
```

## Connecting with MongoDB Compass

Connect to your MongoDB instance using MongoDB Compass with the following connection string:

```
mongodb://mongoAdmin:securePassword@localhost:27017/admin
```

Replace `mongoAdmin` and `securePassword` with your actual credentials.

## File Locations

The container uses standard Debian MongoDB paths:

- Configuration: `/etc/mongod.conf`
- Data files: `/var/lib/mongodb`
- Log files: `/var/log/mongodb`

## Persistent Storage

To persist MongoDB data, mount volumes:

```bash
docker run -d -p 27017:27017 \
  -v mongodb-data:/var/lib/mongodb \
  -v mongodb-logs:/var/log/mongodb \
  --name mongodb minimal-mongodb:latest
```

## License

MIT