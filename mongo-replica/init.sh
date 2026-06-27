#!/bin/bash

echo "Waiting for MongoDB to be ready..."
sleep 15

# Test connection
until mongosh --host mongo1:27017 -u "${MONGO_ROOT_USERNAME}" -p "${MONGO_ROOT_PASSWORD}" --authenticationDatabase admin --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
  echo "Waiting for MongoDB connection..."
  sleep 5
done

echo "MongoDB is ready, initializing replica set..."

mongosh --host mongo1:27017 \
  -u "${MONGO_ROOT_USERNAME}" \
  -p "${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase admin \
  --eval "
    var MONGO_DB_USER='${MONGO_DB_USER}';
    var MONGO_DB_PASSWORD='${MONGO_DB_PASSWORD}';
  " \
  --file /init.js

if [ $? -eq 0 ]; then
  echo "Initialization completed successfully"
else
  echo "Initialization failed"
  exit 1
fi
