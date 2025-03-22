# Ultra-Minimalist MongoDB Docker Image

This repository contains scripts to create the most minimal MongoDB Docker image possible, with no unnecessary components. The approach focuses on creating an image with only the exact files MongoDB needs to function.

## Features

- Creates an extremely small MongoDB container
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Uses an aggressive minimization approach - only MongoDB-related files remain
- Avoids using Dockerfile for a more streamlined build process

## The Minimization Approach

Our scripts use a three-phase minimization approach:

1. **Precision Selection**:
   - Only the MongoDB binaries (mongod, mongosh) are preserved
   - Every binary is fully stripped with `--strip-all` to reduce size
   - Only the required shared libraries are identified and kept
   - Recursive dependency analysis ensures all needed libraries are included
   - Only the essential timezone data MongoDB requires is preserved
   - No debugging tools or shell utilities are included
   
2. **Filesystem Cleanup**:
   - Removes the entire filesystem with `rm -rf /*`
   - Eliminates all unnecessary files and directories
   
3. **Minimal Reconstruction**:
   - Rebuilds with only the exact files needed for MongoDB
   - Creates a minimal root filesystem with only required paths
   - Uses standard MongoDB UID/GID (999) for proper permissions
   - Creates minimal configuration files
   - Results in a highly optimized image

This approach creates a MongoDB image that is significantly smaller than standard MongoDB images (potentially 80-90% smaller), containing only what's required for MongoDB to function.

## Scripts

Two scripts are provided:

1. `build-minimal-mongodb.sh` - For Linux/macOS users
2. `build-minimal-mongodb.bat` - For Windows users

Both scripts produce identical Docker images.

## Requirements

- Docker installed and running
- Internet connection (to download MongoDB packages during build)
- Administrative/sudo access (to run Docker commands)

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

On first run, you need to set up a MongoDB user for authentication:

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

To persist MongoDB data between container restarts, mount volumes:

```bash
docker run -d -p 27017:27017 \
  -v mongodb-data:/var/lib/mongodb \
  -v mongodb-logs:/var/log/mongodb \
  --name mongodb minimal-mongodb:latest
```

## Troubleshooting

Since this container is extremely minimal:
- There are no debugging tools inside the container
- Use `docker logs mongodb` to view MongoDB logs
- Use MongoDB Compass or the MongoDB shell to interact with the database

## License

MIT