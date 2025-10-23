# Creating New Application Databases on Percona MySQL

Repeatable playbook for creating isolated application databases on aries-db1 (Proxmox LXC 101).

## Quick Reference

**MySQL Server**: aries-db1 (10.0.0.131)
**Database**: Percona MySQL 8.0
**Root Access**: `mysql -uroot` (from inside container)
**Monitoring**: mysqld_exporter on port 9104

## Table of Contents

1. [Level A: Per-App Database (Recommended)](#level-a-per-app-database-recommended)
2. [Level B: Separate MySQL Instance](#level-b-separate-mysql-instance)
3. [Firewall Configuration](#firewall-configuration)
4. [Verification & Testing](#verification--testing)
5. [Backup Configuration](#backup-configuration)
6. [Troubleshooting](#troubleshooting)

---

## Level A: Per-App Database (Recommended)

Creates a dedicated database and user within the existing MySQL instance. Suitable for most applications.

### Prerequisites

- Root access to aries-db1 container (CT 101)
- Application server IP address
- Strong password (min 12 chars, mixed case, numbers, symbols)

### Step 1: Define Variables

Replace these placeholders:
- `APPDB` → Database name (e.g., `billing`, `inventory`, `auth_service`)
- `APPUSER` → Application user (e.g., `billing_svc`, `inventory_app`)
- `APP_IP` → Application server IP (e.g., `10.0.0.50` or `10.42.%.%` for Kubernetes pods)
- `STRONG_PASSWORD` → Secure password meeting MySQL requirements

### Step 2: Create Database

```bash
# SSH into aries-db1
ssh root@10.0.0.131

# Create database with UTF8MB4 (full Unicode support)
mysql -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS `APPDB`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;
SQL
```

**Character Set Notes**:
- `utf8mb4` supports full Unicode including emojis (4-byte characters)
- `utf8mb4_0900_ai_ci` is MySQL 8.0's improved collation (accent-insensitive, case-insensitive)
- For case-sensitive: use `utf8mb4_0900_as_cs`

### Step 3: Create Application User

```bash
mysql -uroot <<'SQL'
CREATE USER IF NOT EXISTS 'APPUSER'@'APP_IP'
  IDENTIFIED WITH caching_sha2_password BY 'STRONG_PASSWORD'
  PASSWORD EXPIRE NEVER;

-- Grant minimal privileges for typical CRUD applications
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, EXECUTE
  ON `APPDB`.* TO 'APPUSER'@'APP_IP';

-- Limit concurrent connections to prevent resource exhaustion
ALTER USER 'APPUSER'@'APP_IP' WITH MAX_USER_CONNECTIONS 30;

FLUSH PRIVILEGES;
SQL
```

**Privilege Breakdown**:
- `SELECT, INSERT, UPDATE, DELETE` - CRUD operations
- `CREATE, ALTER, INDEX` - Schema migrations
- `EXECUTE` - Stored procedures/functions
- **NOT GRANTED**: `DROP, GRANT, SUPER, FILE, PROCESS` - Administrative privileges

### Step 4: Verify User Creation

```bash
mysql -uroot -e "SELECT user, host, account_locked, password_expired FROM mysql.user WHERE user='APPUSER';"
mysql -uroot -e "SHOW GRANTS FOR 'APPUSER'@'APP_IP';"
```

### Example: Creating a Billing Database

```bash
# Complete example for a billing application
mysql -uroot <<'SQL'
-- 1. Create database
CREATE DATABASE IF NOT EXISTS `billing`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

-- 2. Create user (app server at 10.0.0.50)
CREATE USER IF NOT EXISTS 'billing_svc'@'10.0.0.50'
  IDENTIFIED WITH caching_sha2_password BY 'B1ll!ng$ecur3P@ss2024'
  PASSWORD EXPIRE NEVER;

-- 3. Grant privileges
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, EXECUTE
  ON `billing`.* TO 'billing_svc'@'10.0.0.50';

-- 4. Set connection limit
ALTER USER 'billing_svc'@'10.0.0.50' WITH MAX_USER_CONNECTIONS 30;

FLUSH PRIVILEGES;
SQL

# Test connection from app server
mysql -h 10.0.0.131 -u billing_svc -p'B1ll!ng$ecur3P@ss2024' billing -e "SELECT DATABASE(), CURRENT_USER();"
```

### Kubernetes Pod Access Pattern

For apps running in Kubernetes, use wildcard host patterns:

```sql
-- Allow access from any pod in Kubernetes cluster (10.42.0.0/16)
CREATE USER IF NOT EXISTS 'APPUSER'@'10.42.%.%'
  IDENTIFIED WITH caching_sha2_password BY 'STRONG_PASSWORD'
  PASSWORD EXPIRE NEVER;

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, EXECUTE
  ON `APPDB`.* TO 'APPUSER'@'10.42.%.%';

ALTER USER 'APPUSER'@'10.42.%.%' WITH MAX_USER_CONNECTIONS 50;

FLUSH PRIVILEGES;
```

---

## Level B: Separate MySQL Instance

Creates a completely isolated MySQL instance on a different port with separate data directory. Use for:
- High-security applications requiring full isolation
- Different MySQL versions
- Independent resource limits
- Strict regulatory compliance

### Prerequisites

- Root access to aries-db1 container
- Available port (e.g., 3307, 3308)
- Sufficient disk space for separate datadir

### Step 1: Create Data Directory

```bash
# Create isolated data directory
mkdir -p /var/lib/mysql-APPNAME
chown mysql:mysql /var/lib/mysql-APPNAME
chmod 750 /var/lib/mysql-APPNAME
```

### Step 2: Initialize MySQL Instance

```bash
# Initialize new MySQL datadir
mysqld --initialize-insecure \
  --user=mysql \
  --datadir=/var/lib/mysql-APPNAME

# Set secure permissions
chown -R mysql:mysql /var/lib/mysql-APPNAME
```

### Step 3: Create Systemd Service

```bash
cat > /etc/systemd/system/mysql-APPNAME.service <<'EOF'
[Unit]
Description=MySQL Server for APPNAME
After=network.target

[Service]
Type=notify
User=mysql
Group=mysql
ExecStart=/usr/sbin/mysqld \
  --defaults-file=/etc/mysql/mysql-APPNAME.cnf \
  --daemonize=OFF
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
```

### Step 4: Create Configuration File

```bash
cat > /etc/mysql/mysql-APPNAME.cnf <<'EOF'
[mysqld]
# Server identification
port = 3307
socket = /var/run/mysqld/mysqld-APPNAME.sock
datadir = /var/lib/mysql-APPNAME
pid-file = /var/run/mysqld/mysqld-APPNAME.pid

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_0900_ai_ci

# Logging
log-error = /var/log/mysql/mysql-APPNAME-error.log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mysql-APPNAME-slow.log
long_query_time = 2

# Performance
max_connections = 100
innodb_buffer_pool_size = 512M

# Security
bind-address = 0.0.0.0
skip-name-resolve
EOF
```

### Step 5: Start and Enable Service

```bash
# Create log directory
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

# Start service
systemctl daemon-reload
systemctl start mysql-APPNAME
systemctl enable mysql-APPNAME

# Check status
systemctl status mysql-APPNAME
```

### Step 6: Secure Instance and Create Database

```bash
# Connect to new instance
mysql --socket=/var/run/mysqld/mysqld-APPNAME.sock

# Inside MySQL shell:
ALTER USER 'root'@'localhost' IDENTIFIED BY 'STRONG_ROOT_PASSWORD';

CREATE DATABASE IF NOT EXISTS `APPDB`
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'APPUSER'@'APP_IP'
  IDENTIFIED WITH caching_sha2_password BY 'STRONG_PASSWORD'
  PASSWORD EXPIRE NEVER;

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, EXECUTE
  ON `APPDB`.* TO 'APPUSER'@'APP_IP';

ALTER USER 'APPUSER'@'APP_IP' WITH MAX_USER_CONNECTIONS 30;

FLUSH PRIVILEGES;
```

### Step 7: Configure Monitoring for New Instance

```bash
# Create exporter user
mysql --socket=/var/run/mysqld/mysqld-APPNAME.sock -uroot -p <<'SQL'
CREATE USER IF NOT EXISTS 'exporter'@'localhost'
  IDENTIFIED WITH mysql_native_password BY 'EXPORTER_PASSWORD'
  WITH MAX_USER_CONNECTIONS 3;

GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
FLUSH PRIVILEGES;
SQL

# Create exporter config
cat > /etc/mysqld_exporter-APPNAME/.my.cnf <<EOF
[client]
user=exporter
password=EXPORTER_PASSWORD
socket=/var/run/mysqld/mysqld-APPNAME.sock
EOF

chmod 600 /etc/mysqld_exporter-APPNAME/.my.cnf

# Create systemd service for exporter
cat > /etc/systemd/system/mysqld_exporter-APPNAME.service <<EOF
[Unit]
Description=Prometheus MySQL Exporter for APPNAME
After=mysql-APPNAME.service

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/mysqld_exporter \\
  --config.my-cnf=/etc/mysqld_exporter-APPNAME/.my.cnf \\
  --web.listen-address=0.0.0.0:9105
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start mysqld_exporter-APPNAME
systemctl enable mysqld_exporter-APPNAME
```

---

## Firewall Configuration

### UFW Rules (Ubuntu/Debian)

```bash
# Allow MySQL from specific app server
ufw allow from APP_IP to any port 3306 proto tcp comment 'MySQL for APPNAME'

# For separate instance on port 3307
ufw allow from APP_IP to any port 3307 proto tcp comment 'MySQL-APPNAME'

# Allow monitoring from Kubernetes cluster
ufw allow from 10.42.0.0/16 to any port 9104 proto tcp comment 'MySQL exporter'

# Reload firewall
ufw reload
```

### Firewalld (RHEL/CentOS)

```bash
# Create rich rule for specific app
firewall-cmd --permanent --add-rich-rule='
  rule family="ipv4"
  source address="APP_IP"
  port protocol="tcp" port="3306"
  accept'

# Reload
firewall-cmd --reload
```

### IPTables (Manual)

```bash
# Allow MySQL from app server
iptables -A INPUT -s APP_IP -p tcp --dport 3306 -j ACCEPT -m comment --comment "MySQL for APPNAME"

# Save rules
iptables-save > /etc/iptables/rules.v4
```

---

## Verification & Testing

### 1. Test Database Connection

```bash
# From app server - test connectivity
nc -zv 10.0.0.131 3306

# Test MySQL authentication
mysql -h 10.0.0.131 -u APPUSER -p'STRONG_PASSWORD' APPDB -e "SELECT 'Connection successful' AS status;"
```

### 2. Verify User Privileges

```bash
# Check granted privileges
mysql -h 10.0.0.131 -u APPUSER -p'STRONG_PASSWORD' APPDB -e "SHOW GRANTS;"

# Test CRUD operations
mysql -h 10.0.0.131 -u APPUSER -p'STRONG_PASSWORD' APPDB <<'SQL'
-- Create test table
CREATE TABLE IF NOT EXISTS connection_test (
  id INT AUTO_INCREMENT PRIMARY KEY,
  test_data VARCHAR(100),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert test data
INSERT INTO connection_test (test_data) VALUES ('Test successful');

-- Read data
SELECT * FROM connection_test;

-- Update data
UPDATE connection_test SET test_data = 'Test updated' WHERE id = 1;

-- Clean up
DROP TABLE connection_test;
SQL
```

### 3. Check Connection Limits

```bash
# View current connections
mysql -h 10.0.0.131 -uroot -e "SHOW PROCESSLIST;"

# Check user connection count
mysql -h 10.0.0.131 -uroot -e "
  SELECT user, COUNT(*) as connections
  FROM information_schema.processlist
  WHERE user = 'APPUSER'
  GROUP BY user;"
```

### 4. Verify Monitoring

```bash
# Check mysqld_exporter metrics
curl -s http://10.0.0.131:9104/metrics | grep mysql_up

# Check Prometheus scraping
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
curl 'http://localhost:9090/api/v1/query?query=mysql_up'

# View in Grafana
# https://monitoring.sidapi.com → MySQL Overview dashboard
```

---

## Backup Configuration

### 1. Add Database to Backup Script

```bash
# Edit backup script
nano /usr/local/bin/mysql-backup.sh

# Add to databases array
DATABASES=("billing" "inventory" "APPDB")
```

### 2. Manual Backup

```bash
# Full database backup
mysqldump -uroot APPDB --single-transaction --routines --triggers \
  | gzip > /backup/mysql/APPDB-$(date +%Y%m%d-%H%M%S).sql.gz

# Schema-only backup
mysqldump -uroot APPDB --no-data --routines --triggers \
  > /backup/mysql/APPDB-schema.sql
```

### 3. Restore from Backup

```bash
# Restore full backup
gunzip < /backup/mysql/APPDB-20241023-120000.sql.gz | mysql -uroot APPDB

# Restore from plain SQL
mysql -uroot APPDB < /backup/mysql/APPDB-schema.sql
```

---

## Troubleshooting

### Connection Refused

```bash
# Check MySQL is listening
netstat -tlnp | grep 3306

# Check bind-address in config
grep bind-address /etc/mysql/my.cnf

# Should be 0.0.0.0 for external access, not 127.0.0.1
```

### Authentication Failed

```bash
# Verify user exists
mysql -uroot -e "SELECT user, host, plugin FROM mysql.user WHERE user='APPUSER';"

# Check authentication plugin
# If using caching_sha2_password, ensure client supports it
# Legacy clients may need mysql_native_password:

mysql -uroot <<SQL
ALTER USER 'APPUSER'@'APP_IP'
  IDENTIFIED WITH mysql_native_password BY 'STRONG_PASSWORD';
FLUSH PRIVILEGES;
SQL
```

### Access Denied Errors

```bash
# Check privileges
mysql -uroot -e "SHOW GRANTS FOR 'APPUSER'@'APP_IP';"

# Grant missing privileges
mysql -uroot <<SQL
GRANT MISSING_PRIVILEGE ON APPDB.* TO 'APPUSER'@'APP_IP';
FLUSH PRIVILEGES;
SQL
```

### Too Many Connections

```bash
# Check current connections
mysql -uroot -e "SHOW PROCESSLIST;"

# Check max_connections limit
mysql -uroot -e "SHOW VARIABLES LIKE 'max_connections';"

# Increase global limit (requires restart)
# Edit /etc/mysql/my.cnf:
# max_connections = 200

# Or increase user limit
mysql -uroot <<SQL
ALTER USER 'APPUSER'@'APP_IP' WITH MAX_USER_CONNECTIONS 50;
FLUSH PRIVILEGES;
SQL
```

### Slow Queries

```bash
# Enable slow query log (if not already enabled)
mysql -uroot <<SQL
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 2;
SQL

# Analyze slow queries
tail -f /var/log/mysql/mysql-slow.log

# Check for missing indexes
mysql -uroot APPDB -e "
  SELECT DISTINCT
    CONCAT(table_schema, '.', table_name) AS table_name,
    index_name
  FROM information_schema.statistics
  WHERE table_schema = 'APPDB'
  ORDER BY table_name;"
```

---

## Security Best Practices

### 1. Password Requirements

- **Minimum length**: 12 characters
- **Complexity**: Mixed case, numbers, symbols
- **Avoid**: Dictionary words, predictable patterns
- **Rotate**: Change passwords every 90 days for production

### 2. Principle of Least Privilege

```sql
-- ❌ NEVER grant ALL PRIVILEGES
GRANT ALL PRIVILEGES ON *.* TO 'user'@'host';  -- TOO PERMISSIVE

-- ✅ Grant only required privileges
GRANT SELECT, INSERT, UPDATE, DELETE ON APPDB.* TO 'user'@'host';
```

### 3. Network Restrictions

```sql
-- ❌ NEVER use wildcard host for production
CREATE USER 'app'@'%' IDENTIFIED BY 'password';  -- TOO OPEN

-- ✅ Restrict to specific IP or subnet
CREATE USER 'app'@'10.0.0.50' IDENTIFIED BY 'password';
CREATE USER 'app'@'10.42.%.%' IDENTIFIED BY 'password';  -- Kubernetes pods
```

### 4. Connection Limits

```sql
-- Always set MAX_USER_CONNECTIONS to prevent resource exhaustion
ALTER USER 'APPUSER'@'APP_IP' WITH MAX_USER_CONNECTIONS 30;
```

### 5. Audit Logging (Optional)

```bash
# Enable audit plugin for compliance
mysql -uroot <<SQL
INSTALL PLUGIN audit_log SONAME 'audit_log.so';
SET GLOBAL audit_log_file = '/var/log/mysql/audit.log';
SQL
```

---

## Quick Reference Commands

```bash
# List all databases
mysql -uroot -e "SHOW DATABASES;"

# List all users
mysql -uroot -e "SELECT user, host FROM mysql.user;"

# Show database size
mysql -uroot -e "
  SELECT
    table_schema AS 'Database',
    ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
  FROM information_schema.tables
  WHERE table_schema = 'APPDB'
  GROUP BY table_schema;"

# Check connection count by user
mysql -uroot -e "
  SELECT user, COUNT(*) as connections
  FROM information_schema.processlist
  GROUP BY user;"

# Kill a connection
mysql -uroot -e "KILL CONNECTION_ID;"

# Drop database (CAREFUL!)
mysql -uroot -e "DROP DATABASE IF EXISTS APPDB;"

# Drop user
mysql -uroot -e "DROP USER IF EXISTS 'APPUSER'@'APP_IP';"
```

---

## Related Documentation

- **MySQL Monitoring Setup**: `/Users/sb/Documents/aries-homelab/Databases/mysql-prometheus-monitoring.md`
- **Grafana Dashboard**: https://monitoring.sidapi.com → MySQL Overview
- **Backup Strategy**: `/Users/sb/Documents/aries-homelab/Databases/backup-strategy.md` (TODO)
- **Percona MySQL Docs**: https://docs.percona.com/percona-server/8.0/

---

## Checklist for New Database

- [ ] Define database name, user, app IP, and passwords
- [ ] Create database with utf8mb4 character set
- [ ] Create user with least-privilege grants
- [ ] Set MAX_USER_CONNECTIONS limit
- [ ] Configure firewall rules
- [ ] Test connection from app server
- [ ] Verify CRUD operations work
- [ ] Add database to backup script
- [ ] Configure monitoring (if separate instance)
- [ ] Document database in project README
- [ ] Store credentials in secure vault (SOPS, Vault, etc.)

---

**Last Updated**: 2025-10-23
**Maintained By**: Infrastructure Team
**MySQL Version**: Percona MySQL 8.0
**Server**: aries-db1 (10.0.0.131)
