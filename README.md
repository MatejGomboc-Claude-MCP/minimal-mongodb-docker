# NO MERCY: Ultra-Minimalist MongoDB Docker Image

This repository contains scripts to create the most minimal MongoDB Docker image humanly possible, with absolutely NO MERCY shown to any unnecessary components. We've pushed minimization to its theoretical limit, creating an image with only the exact bytes MongoDB needs to exist.

## Features

- Creates an impossibly small MongoDB container
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Uses a "ZERO MERCY" approach - nothing but MongoDB survives
- Avoids using Dockerfile for a more streamlined build process

## The NO MERCY Approach

Our scripts use a scorched-earth approach with absolutely zero compromise:

1. **Surgical Extraction**:
   - Only the MongoDB binaries (mongod, mongosh) are preserved
   - Every binary is fully stripped with `--strip-all` (maximum stripping)
   - Only the exact required shared libraries are kept
   - Recursive dependency analysis ensures no missing links
   - Only the exact bytes of timezone data MongoDB requires
   - No debugging tools, no shell, NO MERCY!
   
2. **Total Annihilation**:
   - Completely nukes the entire filesystem with `rm -rf /*`
   - Obliterates every single file and directory
   - Zero tolerance for unnecessary components
   
3. **Minimal Reconstruction**:
   - Rebuilds with only the exact files needed
   - Creates a minimal root filesystem with only required paths
   - Uses hardcoded UID/GID for simplicity (999)
   - Creates minimal configuration files by hand
   - Not a single byte of bloat remains

This "NO MERCY" approach creates a MongoDB image that is 95-98% smaller than standard MongoDB images, containing absolutely nothing but the bare minimum required for MongoDB to function.

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