#!/bin/bash
# Startup script for the Mongo VM. Runs on every boot; every step is idempotent.
# Installs MongoDB 4.4 (EOL) on Ubuntu 20.04, enables auth, creates users, installs the daily backup cron,
# and ships auth.log + mongod.log to Cloud Logging through the Ops Agent (the detective control's data source).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v mongod >/dev/null; then
  apt-get update
  apt-get install -y gnupg curl
  curl -fsSL https://www.mongodb.org/static/pgp/server-4.4.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-4.4.gpg
  echo "deb [signed-by=/usr/share/keyrings/mongodb-4.4.gpg] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org-4.4.list
  apt-get update
  apt-get install -y mongodb-org=4.4.29 mongodb-org-server=4.4.29 mongodb-org-shell=4.4.29 mongodb-org-tools=4.4.29
  echo "mongodb-org hold" | dpkg --set-selections
fi

# Listen on all interfaces (firewall restricts 27017 to the GKE ranges) and require authentication.
cat > /etc/mongod.conf <<'CONF'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
net:
  port: 27017
  bindIp: 0.0.0.0
security:
  authorization: enabled
CONF

systemctl enable mongod
systemctl restart mongod
for i in $(seq 1 30); do mongo --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break; sleep 2; done

# Create users once (the admin user exists after first run; the check uses localhost exception before auth is populated).
if ! mongo --quiet -u admin -p '${admin_password}' --authenticationDatabase admin --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; then
  mongo --quiet admin --eval 'db.createUser({user:"admin", pwd:"${admin_password}", roles:[{role:"root", db:"admin"}]})' || true
fi
mongo --quiet -u admin -p '${admin_password}' --authenticationDatabase admin todo --eval '
  if (!db.getUser("tasky")) { db.createUser({user:"tasky", pwd:"${app_password}", roles:[{role:"readWrite", db:"todo"}]}) }'

# Daily backup to the (public) bucket. Requirement: automated daily backups to object storage.
cat > /usr/local/bin/mongo-backup.sh <<'BK'
#!/bin/bash
set -euo pipefail
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=/tmp/todo-$STAMP.archive.gz
mongodump --uri="mongodb://admin:${admin_password}@127.0.0.1:27017/todo?authSource=admin" --archive="$OUT" --gzip
gsutil cp "$OUT" "gs://${backup_bucket}/backups/todo-$STAMP.archive.gz"
rm -f "$OUT"
echo "backup ok $STAMP"
BK
chmod 700 /usr/local/bin/mongo-backup.sh
echo "15 3 * * * root /usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1" > /etc/cron.d/mongo-backup
chmod 644 /etc/cron.d/mongo-backup

# Ops Agent: ship sshd auth events and mongod logs so Cloud Logging alerts can see them.
if ! systemctl is-active --quiet google-cloud-ops-agent; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
fi
cat > /etc/google-cloud-ops-agent/config.yaml <<'OPS'
logging:
  receivers:
    auth: { type: files, include_paths: [/var/log/auth.log] }
    mongod: { type: files, include_paths: [/var/log/mongodb/mongod.log] }
    backup: { type: files, include_paths: [/var/log/mongo-backup.log] }
  service:
    pipelines:
      default_pipeline: { receivers: [auth, mongod, backup] }
OPS
systemctl restart google-cloud-ops-agent || true

# First backup right away so the bucket has something to show.
/usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1 || true
