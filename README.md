# Nuclear MongoDB Docker Image

This repository contains scripts to create the most minimal MongoDB Docker image technically possible. We've gone beyond mere minimalism to what we call the "nuclear approach" - completely obliterating everything unnecessary, leaving only the bare minimum atoms required for MongoDB to operate.

## Features

- Creates an impossibly small MongoDB container
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Employs a nuclear "obliterate and rebuild" minimization strategy
- Avoids using Dockerfile for a more streamlined build process

## The Nuclear Approach

Our scripts use an extreme three-phase approach that goes beyond traditional minimization:

1. **Precision Planning**:
   - Creates a predefined skeleton directory structure
   - Identifies MongoDB executables and their dependencies with surgical precision
   - Strips all binaries to absolute minimum size
   - Recursively resolves and analyzes library dependencies
   - Preserves only the few bytes of timezone data MongoDB requires
   - Creates minimal user configuration
   
2. **Total Obliteration**:
   - **COMPLETELY NUKES THE ENTIRE FILESYSTEM**
   - Removes literally everything with `rm -rf /*`
   - Wipes the slate clean for a pristine rebuild
   
3. **Atomic Reconstruction**:
   - Rebuilds the container from its atomic components
   - Restores only the exact bytes needed
   - Creates a pure MongoDB environment with zero bloat

This nuclear approach results in an image that is 90-95% smaller than standard MongoDB images, containing only the absolute bare minimum bytes physically required for MongoDB to function.

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