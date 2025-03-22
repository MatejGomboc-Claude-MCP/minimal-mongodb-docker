# Extreme Minimal MongoDB Docker Image

This repository contains scripts to create the smallest possible MongoDB Docker image using standard Debian paths. The approach focuses on eliminating virtually everything except the essential MongoDB files required for operation.

## Features

- Creates the absolute minimum MongoDB container possible
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Achieves extreme minimization with a "delete everything" approach
- Avoids using Dockerfile for a more streamlined build process

## Extreme "Delete Everything" Approach

The scripts use a two-phase approach to create a truly minimal image:

1. **Preservation Phase**:
   - Identifies the MongoDB binaries (mongod, mongosh)
   - Uses `ldd` to find all library dependencies
   - Copies only these essential files to a temporary location
   - Preserves required timezone data and configuration
   - Saves MongoDB user information
   
2. **Deletion Phase**:
   - **DELETES EVERYTHING** in the filesystem
   - Removes all binaries, libraries, and system files
   - Completely wipes out the container
   
3. **Restoration Phase**:
   - Restores only the exact files MongoDB needs to function
   - Reinstates only the required libraries and configuration
   - Rebuilds a minimal system with only MongoDB essentials

This radical approach results in a Docker image that is typically 80-90% smaller than standard MongoDB images while maintaining full functionality.

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