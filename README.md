# Ultra-Minimalist MongoDB Docker Image

This repository contains scripts to create the most minimal MongoDB Docker image possible. The approach focuses on creating an image with only the MongoDB server binary and its required dependencies, with no shell or additional tools.

## Features

- Creates an extremely small MongoDB container (potentially 85-95% smaller than standard images)
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Includes only the MongoDB server - no shell, no utilities
- Avoids using Dockerfile for a more streamlined build process

## The Minimization Approach

Our scripts use a three-phase minimization approach:

1. **Precision Selection**:
   - Only the MongoDB server binary (mongod) is preserved
   - The binary is fully stripped with `--strip-all` to reduce size
   - Only the required shared libraries are identified and kept
   - Recursive dependency analysis ensures all needed libraries are included
   - Only the essential timezone data MongoDB requires is preserved
   - No shell, no mongosh, no utilities of any kind
   
2. **Filesystem Cleanup**:
   - Removes the entire filesystem with `rm -rf /*`
   - Eliminates all unnecessary files and directories
   
3. **Minimal Reconstruction**:
   - Rebuilds with only the exact files needed for the MongoDB server
   - Creates a minimal root filesystem with only required paths
   - Uses standard MongoDB UID/GID (999) for proper permissions
   - Creates minimal configuration files
   - Results in a highly optimized image

## Scripts

Two scripts are provided:

1. `build-minimal-mongodb.sh` - For Linux/macOS users
2. `build-minimal-mongodb.bat` - For Windows users

Both scripts produce identical Docker images.

## Requirements

- Docker installed and running
- Internet connection (to download MongoDB packages during build)
- Administrative/sudo access (to run Docker commands)
- MongoDB Compass installed on your host machine (for database management)

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

## Database Management

Since this image does not include the MongoDB shell (mongosh), all database management must be done remotely through MongoDB Compass or another client.

### Initial User Setup with Docker and mongosh

To create the first admin user, you'll temporarily need mongosh. If you don't have it installed, you can use a standard MongoDB container just for this purpose:

```bash
# Start the minimal MongoDB instance without authentication temporarily
docker run -d -p 27017:27017 --name mongodb-minimal minimal-mongodb:latest mongod --config /etc/mongod.conf --auth false

# Use a temporary standard MongoDB container to connect and create an admin user
docker run --rm -it --network host mongo:latest mongosh --eval '
  db = db.getSiblingDB("admin");
  db.createUser({
    user: "mongoAdmin",
    pwd: "securePassword",  // Change this!
    roles: [ { role: "userAdminAnyDatabase", db: "admin" }, "readWriteAnyDatabase" ]
  });
  quit();
'

# Stop the minimal MongoDB instance
docker stop mongodb-minimal
docker rm mongodb-minimal

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
- There is no shell or MongoDB shell (mongosh)
- Use `docker logs mongodb` to view MongoDB logs
- Use MongoDB Compass for all database operations

## License

MIT