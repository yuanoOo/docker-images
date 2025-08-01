#!/bin/bash
set -e

# =============================================================================
# OceanBase Database Container Deployment Script
# =============================================================================
# This script automates the deployment of OceanBase database cluster in Docker
# Supports customizable tenant name and password via environment variables
# =============================================================================

# Step 1: Environment Variables Configuration
# =============================================================================
CLUSTER_NAME=${CLUSTER_NAME:-"ob"}
OBSERVER_PATCHED=${OBSERVER_PATCHED:-"/home/admin/oceanbase/bin/observer"}
OBPROXY_PATCHED=${OBPROXY_PATCHED:-"/home/admin/obproxy/bin/obproxy"}

# Step 2: Port Configuration
# =============================================================================
JDBC_PORT=2881      # Database connection port
RPC_PORT=2882       # Internal communication port
OBPROXY_PORT=2883   # Proxy connection port

# Step 3: Tenant and Password Configuration
# =============================================================================
TENANT_NAME=${TENANT_NAME:-"test"}           # Tenant name (configurable via Docker env)
PASSWORD=${PASSWORD:-"123456"}               # System password (configurable via Docker env)
PASSWORD_SHA1=$(echo -n "$PASSWORD" | sha1sum | cut -d' ' -f1)  # SHA1 hash for OBProxy

# Step 3.1: Storage Configuration
# =============================================================================
DATAFILE_SIZE=${DATAFILE_SIZE:-"2G"}        # Data file size (configurable via Docker env)
LOG_DISK_SIZE=${LOG_DISK_SIZE:-"4G"}        # Log disk size (configurable via Docker env)

# Step 4: Display Configuration Information
# =============================================================================
echo "=== OceanBase Deployment Configuration ==="
echo "Cluster Name: $CLUSTER_NAME"
echo "Observer Path: $OBSERVER_PATCHED"
echo "OBProxy Path: $OBPROXY_PATCHED"
echo "Ports: JDBC=$JDBC_PORT, RPC=$RPC_PORT, Proxy=$OBPROXY_PORT"
echo "Tenant: $TENANT_NAME, Password: $PASSWORD"
echo "Storage: DataFile=$DATAFILE_SIZE, LogDisk=$LOG_DISK_SIZE"
echo "=========================================="

# Step 5: Start OceanBase Configuration Server
# =============================================================================
echo "Starting OceanBase configuration server..."
obd cluster start config-server

# Step 6: Initialize Data Directories
# =============================================================================
echo "Initializing data directories..."
if [ ! -d "/data" ]; then
    mkdir -p "/home/ds" "/data"
fi
chown -R admin:admin /data

# Step 7: OceanBase Observer Initialization and Startup
# =============================================================================
echo "Starting OceanBase Observer service..."
cat <<EOF | su - admin
cd ~

# Set environment variable for cluster name
if ! grep -q "export cluster_name=" .bashrc; then
    echo "export cluster_name='$CLUSTER_NAME'" >> ~/.bashrc
fi
source .bashrc

# Clean up existing data directories
rm -rf /data/1/'$CLUSTER_NAME'
rm -rf /data/log1/'$CLUSTER_NAME'
rm -rf /home/admin/oceanbase/store/'$CLUSTER_NAME'
rm -rf /home/admin/oceanbase/log/* /home/admin/oceanbase/etc/*config*

# Create data directory structure
mkdir -p /data/1/'$CLUSTER_NAME'/{etc3,sstable,slog}
mkdir -p /data/log1/'$CLUSTER_NAME'/{clog,etc2}
mkdir -p /home/admin/oceanbase/store/'$CLUSTER_NAME'

# Create symbolic links for data mapping
ln -s /data/1/'$CLUSTER_NAME'/etc3 /home/admin/oceanbase/store/'$CLUSTER_NAME'/etc3
ln -s /data/1/'$CLUSTER_NAME'/sstable /home/admin/oceanbase/store/'$CLUSTER_NAME'/sstable
ln -s /data/1/'$CLUSTER_NAME'/slog /home/admin/oceanbase/store/'$CLUSTER_NAME'/slog
ln -s /data/log1/'$CLUSTER_NAME'/clog /home/admin/oceanbase/store/'$CLUSTER_NAME'/clog
ln -s /data/log1/'$CLUSTER_NAME'/etc2 /home/admin/oceanbase/store/'$CLUSTER_NAME'/etc2

# Start OceanBase Observer with configuration
cd /home/admin/oceanbase/store/$CLUSTER_NAME/ && $OBSERVER_PATCHED \
    -I 127.0.0.1 \
    -p $JDBC_PORT \
    -P $RPC_PORT \
    -z zone1 \
    -n $CLUSTER_NAME \
    -d /home/admin/oceanbase/store/$CLUSTER_NAME/ \
    -c 1000 \
    -o "memory_limit=6G,__min_full_resource_pool_memory=1073741824,system_memory=1G,datafile_size=$DATAFILE_SIZE,max_syslog_file_count=2,log_disk_size=$LOG_DISK_SIZE,obconfig_url=http://127.0.0.1:8080/services?Action=ObRootServiceInfo&User_ID=alibaba&UID=admin&ObCluster=$CLUSTER_NAME"

EOF

# Step 8: Wait for Observer to Start
# =============================================================================
echo "Waiting for Observer to start..."
echo "Sleeping for 120 seconds to allow Observer to start..."
sleep 120

echo "Checking Observer status after sleep..."
echo "Observer process status:"
ps aux | grep observer || echo "Observer process not found"

echo "Observer logs (last 10 lines):"
tail -10 /home/admin/oceanbase/store/test/log/observer.log 2>/dev/null || echo "No observer log found"

echo "Checking Observer connection..."
if obclient -h127.0.0.1 -uroot -P $JDBC_PORT -e "SELECT 1;" 2>/dev/null; then
  echo "Observer is ready!"
else
  echo "Observer not ready yet, waiting additional 30 seconds..."
  sleep 30
  echo "Final Observer status check:"
  ps aux | grep observer || echo "Observer process not found"
  tail -10 /home/admin/oceanbase/store/test/log/observer.log 2>/dev/null || echo "No observer log found"
fi

# Step 9: Initialize OceanBase Cluster and Create Users
# =============================================================================
echo "Initializing OceanBase cluster and creating users..."

# Check system resources before cluster initialization
echo "Checking system resources before cluster initialization..."
free -h
df -h

# Add error handling for cluster initialization
set +e
echo "开始分步执行集群初始化命令..."

# 1. 设置会话超时
echo "=== 步骤1: 设置会话超时 ==="
echo "执行命令: SET SESSION ob_query_timeout=1000000000;"
timeout_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "SET SESSION ob_query_timeout=1000000000;" 2>&1)
timeout_exit_code=$?
echo "执行结果 (退出码: $timeout_exit_code):"
echo "$timeout_result"
echo ""

# 2. 初始化集群
echo "=== 步骤2: 初始化集群 ==="
echo "执行命令: ALTER SYSTEM BOOTSTRAP ZONE \"zone1\" SERVER \"127.0.0.1:${RPC_PORT}\";"
bootstrap_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "ALTER SYSTEM BOOTSTRAP ZONE \"zone1\" SERVER \"127.0.0.1:${RPC_PORT}\";" 2>&1)
bootstrap_exit_code=$?
echo "执行结果 (退出码: $bootstrap_exit_code):"
echo "$bootstrap_result"
echo ""

# 3. 设置root用户密码
echo "=== 步骤3: 设置root用户密码 ==="
echo "执行命令: alter user root identified by \"$PASSWORD\";"
root_password_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "alter user root identified by \"$PASSWORD\";" 2>&1)
root_password_exit_code=$?
echo "执行结果 (退出码: $root_password_exit_code):"
echo "$root_password_result"
echo ""

# 4. 创建proxyro用户
echo "=== 步骤4: 创建proxyro用户 ==="
echo "执行命令: CREATE USER proxyro IDENTIFIED BY \"$PASSWORD\";"
proxyro_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "CREATE USER proxyro IDENTIFIED BY \"$PASSWORD\";" 2>&1)
proxyro_exit_code=$?
echo "执行结果 (退出码: $proxyro_exit_code):"
echo "$proxyro_result"
echo ""

# 5. 授权proxyro用户
echo "=== 步骤5: 授权proxyro用户 ==="
echo "执行命令: GRANT SELECT ON *.* TO proxyro;"
grant_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "GRANT SELECT ON *.* TO proxyro;" 2>&1)
grant_exit_code=$?
echo "执行结果 (退出码: $grant_exit_code):"
echo "$grant_result"
echo ""

# 6. 创建资源单元
echo "=== 步骤6: 创建资源单元 ==="
echo "执行命令: CREATE RESOURCE UNIT unit_cf_min MEMORY_SIZE = \"2G\", MAX_CPU = 1, MIN_CPU = 1, LOG_DISK_SIZE = \"2G\", MAX_IOPS = 10000, MIN_IOPS = 10000, IOPS_WEIGHT=1;"
unit_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "CREATE RESOURCE UNIT unit_cf_min MEMORY_SIZE = \"2G\", MAX_CPU = 1, MIN_CPU = 1, LOG_DISK_SIZE = \"2G\", MAX_IOPS = 10000, MIN_IOPS = 10000, IOPS_WEIGHT=1;" 2>&1)
unit_exit_code=$?
echo "执行结果 (退出码: $unit_exit_code):"
echo "$unit_result"
echo ""

# 7. 创建资源池
echo "=== 步骤7: 创建资源池 ==="
echo "执行命令: CREATE RESOURCE POOL rs_pool_1 UNIT=\"unit_cf_min\", UNIT_NUM=1, ZONE_LIST=(\"zone1\");"
pool_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "CREATE RESOURCE POOL rs_pool_1 UNIT=\"unit_cf_min\", UNIT_NUM=1, ZONE_LIST=(\"zone1\");" 2>&1)
pool_exit_code=$?
echo "执行结果 (退出码: $pool_exit_code):"
echo "$pool_result"
echo ""

# 8. 创建租户
echo "=== 步骤8: 创建租户 ==="
echo "执行命令: CREATE TENANT IF NOT EXISTS $TENANT_NAME PRIMARY_ZONE=\"zone1\", RESOURCE_POOL_LIST=(\"rs_pool_1\") set OB_TCP_INVITED_NODES=\"%\", lower_case_table_names = 1;"
tenant_result=$(obclient -h127.0.0.1 -uroot -P $JDBC_PORT -A -e "CREATE TENANT IF NOT EXISTS $TENANT_NAME PRIMARY_ZONE=\"zone1\", RESOURCE_POOL_LIST=(\"rs_pool_1\") set OB_TCP_INVITED_NODES=\"%\", lower_case_table_names = 1;" 2>&1)
tenant_exit_code=$?
echo "执行结果 (退出码: $tenant_exit_code):"
echo "$tenant_result"
echo ""

# 总结执行结果
echo "=== 集群初始化执行总结 ==="
if [ $timeout_exit_code -eq 0 ] && [ $bootstrap_exit_code -eq 0 ] && [ $root_password_exit_code -eq 0 ] && [ $proxyro_exit_code -eq 0 ] && [ $grant_exit_code -eq 0 ] && [ $unit_exit_code -eq 0 ] && [ $pool_exit_code -eq 0 ] && [ $tenant_exit_code -eq 0 ]; then
    echo "✅ 所有步骤执行成功"
    echo "Tenant '$TENANT_NAME' created successfully"
else
    echo "❌ 部分步骤执行失败"
    echo "步骤1(设置超时): $timeout_exit_code"
    echo "步骤2(初始化集群): $bootstrap_exit_code"
    echo "步骤3(设置root密码): $root_password_exit_code"
    echo "步骤4(创建proxyro用户): $proxyro_exit_code"
    echo "步骤5(授权proxyro): $grant_exit_code"
    echo "步骤6(创建资源单元): $unit_exit_code"
    echo "步骤7(创建资源池): $pool_exit_code"
    echo "步骤8(创建租户): $tenant_exit_code"
fi
echo ""

# Step 10: Configure Tenant User Password
# =============================================================================
echo "Configuring tenant user password..."
echo "Setting password for root user in tenant '$TENANT_NAME'..."

# Set password and capture any errors
echo "Executing password set command..."
echo "Command: alter user root identified by '$PASSWORD';"
result=$(obclient -h127.0.0.1 -uroot@$TENANT_NAME -P ${JDBC_PORT} -A -e "alter user root identified by '$PASSWORD';" 2>&1)
echo "Command result: $result"

# Check if password was set successfully
echo "Verifying password was set successfully..."
verify_result=$(obclient -h127.0.0.1 -uroot@$TENANT_NAME -P ${JDBC_PORT} -p$PASSWORD -e "SELECT 1;" 2>&1)
echo "Verification result: $verify_result"
if [ $? -eq 0 ]; then
  echo "✅ Password for tenant '$TENANT_NAME' was set successfully"
else
  echo "❌ Failed to verify password for tenant '$TENANT_NAME'"
fi

# Step 11: Start OBProxy Service
# =============================================================================
echo "Starting OBProxy service..."
cat <<EOF | su - admin
source .bashrc
cd /home/admin/obproxy && $OBPROXY_PATCHED \
    -r "127.0.0.1:$JDBC_PORT" \
    -p $OBPROXY_PORT \
    -o "observer_sys_password=$PASSWORD_SHA1,enable_strict_kernel_release=false,enable_cluster_checkout=false,enable_metadb_used=false,obproxy_config_server_url=http://127.0.0.1:8080/services?Action=GetObProxyConfig&User_ID=alibaba&UID=admin" \
    -c $CLUSTER_NAME
EOF

# Step 12: Install and Configure Binlog Service
# =============================================================================
echo "Installing and configuring binlog service..."

# Check for obbinlog RPM package
rpm_files=$(ls /app/obbinlog-*.rpm 2> /dev/null)

if [ -n "$rpm_files" ]; then
    echo "Installing obbinlog package..."
    rpm -ivh --replacefiles /app/obbinlog-*.rpm
fi

sleep 5

# Step 13: Configure Binlog Service
# =============================================================================
echo "Configuring binlog service..."
node_ip=$(hostname -i)
cat <<EOF > /home/ds/oblogproxy/env/deploy.conf.json
{
  "host": "127.0.0.1",
  "node_ip": "$node_ip",
  "port": $OBPROXY_PORT,
  "user": "root@sys",
  "password": "$PASSWORD",
  "database": "",
  "sys_user": "root",
  "sys_password": "$PASSWORD",
  "supervise_start": "false",
  "init_schema": ""
}
EOF

# Step 14: Deploy and Start Binlog Service
# =============================================================================
echo "Deploying binlog service..."
source /etc/profile
cd /home/ds/oblogproxy/env/
sh deploy.sh -m deploy -f deploy.conf.json

echo "Binlog service is running"

# Step 15: Configure OBProxy Binlog Settings
# =============================================================================
echo "Configuring OBProxy binlog settings..."
obclient -h127.0.0.1 -uroot@sys -P$OBPROXY_PORT -A -p$PASSWORD <<EOF
alter proxyconfig set binlog_service_ip="127.0.0.1:2983";
alter proxyconfig set init_sql="set _show_ddl_in_compat_mode = 1;";
EOF

# Step 16: Create Binlog for Tenant
# =============================================================================
echo "Creating binlog for tenant..."
sleep 20
obclient -A -c -h 127.0.0.1 -P2983 <<EOF
CREATE BINLOG FOR TENANT ${CLUSTER_NAME}.$TENANT_NAME WITH CLUSTER URL "http://127.0.0.1:8080/services?Action=ObRootServiceInfo&User_ID=alibaba&UID=admin&ObCluster=${CLUSTER_NAME}";
EOF
echo "Binlog created successfully for tenant '$TENANT_NAME'"

# Step 17: Keep Container Running
# =============================================================================
echo "OceanBase deployment completed successfully!"
echo "Container will keep running..."

# Check final system resources
echo "Final system resources check:"
free -h
df -h

# Keep container running with error handling
set -e
while true; do
  echo "Container is running... $(date)"
  sleep 30
done