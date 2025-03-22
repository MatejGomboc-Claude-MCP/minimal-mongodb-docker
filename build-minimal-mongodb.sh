#!/bin/bash
set -e

# Error handling function
handle_error() {
  local error_code=$?
  echo "Error: Command failed with exit code $error_code"
  echo "Failed at step: $1"
  
  # Cleanup
  if [ -n "$CONTAINER_ID" ]; then
    echo "Cleaning up container..."
    docker stop $CONTAINER_ID 2>/dev/null || true
    docker rm $CONTAINER_ID 2>/dev/null || true
  fi
  exit $error_code
}

# Set trap to catch errors
trap 'handle_error "${BASH_COMMAND}"' ERR

# Accept parameters with defaults
MONGODB_VERSION="${1:-8.0.6}"
MONGODB_USERNAME="${2:-admin}"
MONGODB_PASSWORD="${3:-admin}"

echo "Building minimal MongoDB image with:"
echo "- MongoDB version: $MONGODB_VERSION"
echo "- Admin username: $MONGODB_USERNAME"
echo "- Admin password: $MONGODB_PASSWORD"

# Step 1: Create a temporary container using a minimal Debian base
echo "Creating temporary container..."
CONTAINER_ID=$(docker run -d debian:bookworm-slim sleep infinity)

# Check container is running
if ! docker ps | grep -q "$CONTAINER_ID"; then
  echo "Container failed to start properly!"
  exit 1
fi

echo "Container created: $CONTAINER_ID"

# Step 2: Copy the minimizer script to the container
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker cp "$SCRIPT_DIR/mongodb-minimizer.sh" "$CONTAINER_ID:/tmp/mongodb-minimizer.sh"

# Step 3: Run the installation and minimization process
echo "Installing and minimizing MongoDB..."
if ! docker exec -e MONGODB_VERSION="$MONGODB_VERSION" \
           -e MONGODB_USERNAME="$MONGODB_USERNAME" \
           -e MONGODB_PASSWORD="$MONGODB_PASSWORD" \
           -e OPERATION="all" \
           "$CONTAINER_ID" bash -c "chmod +x /tmp/mongodb-minimizer.sh && /tmp/mongodb-minimizer.sh"; then
  echo "MongoDB installation or minimization failed!"
  docker stop "$CONTAINER_ID"
  docker rm "$CONTAINER_ID"
  exit 1
fi

# Step 4: Extract Docker commit options from helper script
echo "Getting Docker commit options..."
COMMIT_OPTIONS=$(docker exec -e OPERATION="commit-options" "$CONTAINER_ID" bash -c "chmod +x /tmp/mongodb-minimizer.sh && /tmp/mongodb-minimizer.sh" | 
                 sed -n '/===DOCKER_COMMIT_OPTIONS_START===/,/===DOCKER_COMMIT_OPTIONS_END===/p' | 
                 grep -v "===")

# Step 5: Commit the container to create the image
echo "Creating minimal MongoDB image..."
COMMIT_CMD="docker commit"
while IFS= read -r option; do
  COMMIT_CMD="$COMMIT_CMD $option"
done <<< "$COMMIT_OPTIONS"
COMMIT_CMD="$COMMIT_CMD $CONTAINER_ID minimal-mongodb:latest"
eval "$COMMIT_CMD"

# Step 6: Clean up
docker stop "$CONTAINER_ID"
docker rm "$CONTAINER_ID"

echo "Minimal MongoDB image created as 'minimal-mongodb:latest'"
echo "Image details:"
docker images minimal-mongodb:latest
echo ""
echo "MongoDB credentials:"
echo "Username: $MONGODB_USERNAME"
echo "Password: $MONGODB_PASSWORD"
echo ""
echo "IMPORTANT: Change the default password after first login!"
echo "Usage example: docker run -d -p 27017:27017 --name mongodb minimal-mongodb:latest"
