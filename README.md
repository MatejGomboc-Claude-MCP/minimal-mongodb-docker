# Ultra-Minimalist MongoDB Docker Image

This repository contains scripts to create the most minimal MongoDB Docker image possible. The approach focuses on creating an image with only the MongoDB server binary and its required dependencies, with no shell or additional tools.

## Features

- Creates an extremely small MongoDB container (potentially 85-95% smaller than standard images)
- Uses standard Debian file paths for MongoDB
- Runs MongoDB as the mongodb user for proper security
- Configures MongoDB for remote access (for use with MongoDB Compass)
- Includes only the MongoDB server - no shell, no utilities
- Comes with a configurable admin user
- Provides proper signal handling for graceful container shutdown
- Includes health check for container monitoring
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
   - Performs targeted removal of unnecessary files and directories
   - Eliminates all unneeded components
   
3. **Minimal Reconstruction**:
   - Rebuilds with only the exact files needed for the MongoDB server
   - Creates a minimal root filesystem with only required paths
   - Uses standard MongoDB UID/GID (999) for proper permissions
   - Creates minimal configuration files
   - Pre-configures an admin user with customizable credentials
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

# Run the script with default settings (MongoDB 6.0, admin/mongoadmin credentials)
./build-minimal-mongodb.sh

# Or specify custom MongoDB version and credentials
./build-minimal-mongodb.sh 7.0 myadmin mysecretpassword
```

### Windows

```batch
# Run the script with default settings
build-minimal-mongodb.bat

# Or specify custom MongoDB version and credentials
build-minimal-mongodb.bat 7.0 myadmin mysecretpassword
```

## Running the MongoDB Container

After building the image, you can run it with:

```bash
docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest
```

## Admin User

The image comes with a pre-configured admin user with credentials that can be customized during build. By default:

- **Username**: admin
- **Password**: mongoadmin

**IMPORTANT**: For security reasons, you should change this password immediately after the first login or specify a secure password when building the image.

## Connecting with MongoDB Compass

Connect to your MongoDB instance using MongoDB Compass with the following connection string (replace with your custom credentials if specified during build):

```
mongodb://admin:mongoadmin@localhost:27017/admin
```

After connecting, you should immediately change the admin password if using defaults:

1. Go to the "admin" database
2. Click on "Users" collection
3. Find the admin user and update the password

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

## Health Checks

The image includes a Docker HEALTHCHECK that verifies MongoDB is operating correctly. You can monitor the health status with:

```bash
docker inspect --format='{{.State.Health.Status}}' mongodb
```

## Troubleshooting

Since this container is extremely minimal:
- There are no debugging tools inside the container
- There is no shell or MongoDB shell (mongosh)
- Use `docker logs mongodb` to view MongoDB logs
- Use MongoDB Compass for all database operations

## Size Comparison

The resulting image is typically around 40-60MB compared to:
- Official MongoDB image: 400-600MB
- Official MongoDB slim image: ~200MB

This represents an 85-95% reduction in size while maintaining full MongoDB functionality.

## License

MIT