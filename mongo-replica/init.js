// Connect to admin database for sys ops
db = db.getSiblingDB('admin');

try {
  var rsConf = {
    _id: 'okydookReplSet',
    members: [
      { _id: 0, host: 'mongo1:27017', priority: 2 },
      { _id: 1, host: 'mongo2:27017' },
      { _id: 2, host: 'mongo3:27017' }
    ]
  };
  
  // Check if replica set is already initialized
  var isInitialized = false;
  try {
    var status = rs.status();
    if (status.ok === 1) {
      isInitialized = true;
      print("ReplicaSet already initiated");
    }
  } catch(e) {
    // rs.status() throws error if not initialized yet
    print("ReplicaSet not yet initiated, proceeding with initiation...");
  }
  
  if (!isInitialized) {
    rs.initiate(rsConf);
    print("ReplicaSet initiated successfully");
    
    // Wait for replica set to be ready
    sleep(20000);
  }
} catch(e) {
  print("Failed to initiate replica set: " + e.message);
  throw e;
}

// Wait a bit more to ensure primary is elected
sleep(5000);

// Create application user
try { 
  db = db.getSiblingDB('okydook');
  
  var userExists = db.getUser(process.env.MONGO_DB_USER);
  
  if (!userExists) {
    db.createUser({
      user: process.env.MONGO_DB_USER,
      pwd: process.env.MONGO_DB_PASSWORD,
      roles: [{ role: 'readWrite', db: 'okydook' }]
    });
    print("User created successfully");
  }
} catch(e) {
  print("Failed to create user: " + e.message);
  throw e;
}

print("Initialization completed successfully");
