# Minimal MongoDB Docker Image

This repository contains scripts to create an extremely minimalist MongoDB Docker image using standard Debian paths. The approach focuses on creating the absolute smallest possible functional MongoDB image while maintaining compatibility with MongoDB client tools like Compass.

## Features

- Creates a ultra-minimal MongoDB container based on Debian slim
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Aggressively removes all unnecessary components to minimize image size
- Avoids using Dockerfile for a more streamlined build process

## Minimization Steps

The scripts use several techniques to create a truly minimal image:

1. Starting with a minimal Debian base image
2. Installing only essential MongoDB components
3. Removing package management tools after installation
4. Stripping all binaries to reduce their size
5. Removing all unnecessary files and directories:
   - Documentation, man pages, and locale data
   - Package management files and caches
   - Temporary files and log files
   - Unnecessary timezone data (keeping only what MongoDB needs)
   - Unneeded system utilities

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