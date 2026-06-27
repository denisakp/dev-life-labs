FROM mongo:8.2-noble

# Copy MongoDB replica set keyfile with correct permissions
COPY --chown=mongodb:mongodb --chmod=400 rs_keyfile /etc/mongodb/keyfile

# Copy MongoDB configuration
COPY --chown=mongodb:mongodb --chmod=644 mongod.conf /etc/mongod.conf

# Copy initialization scripts
COPY --chown=mongodb:mongodb --chmod=755 init.sh /init.sh
COPY --chown=mongodb:mongodb --chmod=644 init.js /init.js

# Ensure the keyfile directory has correct permissions
RUN chown -R mongodb:mongodb /etc/mongodb && \
    chmod 700 /etc/mongodb

# Set the default command
CMD ["--config", "/etc/mongod.conf"]
