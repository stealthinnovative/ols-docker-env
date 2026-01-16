#!/usr/bin/env bash
# phpmyadmin.sh - Complete FPM phpMyAdmin automation

set -e

CONT_NAME='litespeed'
EPACE='        '

echow(){
    FLAG=${1}
    shift
    echo -e "\033[1m${EPACE}${FLAG}\033[0m${@}"
}

# Load .env
[ -f .env ] && source .env

echow "➤" "Creating phpMyAdmin FPM External App..."
docker compose exec ${CONT_NAME} su -s /bin/bash lsadm -c "
cat > /usr/local/lsws/conf/httpd_config.conf << 'EOF'
<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<extApp>
    <type>LiteSpeed SAPI</type>
    <name>phpmyadmin-fpm</name>
    <address>udp://phpmyadmin-fpm:9000</address>
    <maxConns>50</maxConns>
    <initTimeout>60</initTimeout>
    <retryTimeout>0</retryTimeout>
    <persistConn>1</persistConn>
    <pcKeepAliveTimeout>1</pcKeepAliveTimeout>
    <respBuffer>0</respBuffer>
    <autoStart>1</autoStart>
    <path></path>
    <initCmd></initCmd>
    <runOnStartUp>0</runOnStartUp>
    <extUser>nobody</extUser>
    <extGroup>nobody</extGroup>
    <umask>0022</umask>
    <swapping>0</swapping>
    <prio>0</prio>
</extApp>
EOF
"

echow "➤" "Creating phpMyAdmin Context..."
docker compose exec ${CONT_NAME} su -s /bin/bash lsadm -c "
cat >> /usr/local/lsws/conf/httpd_config.conf << 'EOF'

context {
  type                    static
  location                /
  uri                     /phpmyadmin
  allowSymbolLink         1
  indexFiles              index.php
  handler                 phpmyadmin-fpm
  rewrite  {
  }
}
EOF
"

echow "➤" "Restarting OpenLiteSpeed..."
docker compose exec ${CONT_NAME} /usr/local/lsws/bin/lswsctrl restart
sleep 3

echow "🔍" "Running verification tests..."

# Test page loads
curl -f -s http://localhost/phpmyadmin/ > /dev/null && echow "✅" "Page loads" || echow "❌" "Page failed"

# Test logins
[ ! -z "\${MYSQL_ROOT_PASSWORD+x}" ] && {
    curl -s -c /tmp/cookies -b /tmp/cookies -d "pma_username=root&pma_password=${MYSQL_ROOT_PASSWORD}&server=1" \
        http://localhost/phpmyadmin/index.php | grep -q "server_databases" && echow "✅" "Root login OK"
    rm -f /tmp/cookies
}

[ ! -z "\${MYSQL_USER+x}" ] && [ ! -z "\${MYSQL_PASSWORD+x}" ] && {
    curl -s -c /tmp/cookies -b /tmp/cookies -d "pma_username=${MYSQL_USER}&pma_password=${MYSQL_PASSWORD}&server=0" \
        http://localhost/phpmyadmin/index.php | grep -q "server_databases" && echow "✅" "User login OK (${MYSQL_USER})"
    rm -f /tmp/cookies
}

echow "🎉" "Complete! Access: http://localhost/phpmyadmin/"
