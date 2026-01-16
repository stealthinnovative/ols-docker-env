#!/usr/bin/env bash
# phpMyAdmin on secure port 8080 + firewall friendly

EPACE='        '
echow(){ FLAG=${1}; shift; echo -e "\033[1m${EPACE}${FLAG}\033[0m${@}"; }

# Download phpMyAdmin 5.2.3
echow "➤" "Installing phpMyAdmin 5.2.3 on port 8080..."
mkdir -p ./sites/phpmyadmin
cd ./sites/phpmyadmin

wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz
tar -xzf phpMyAdmin-5.2.3-all-languages.tar.gz --strip-components=1
rm phpMyAdmin-5.2.3-all-languages.tar.gz

# Auto-config from .env
[ -f ../.env ] && source ../.env
cat > config.inc.php << EOF
<?php
\$cfg['blowfish_secret'] = '$(openssl rand -base64 32)';
\$i = 0; \$i++;
\$cfg['Servers'][\$i]['host'] = 'mysql';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['user'] = '${MYSQL_USER:-root}';
\$cfg['Servers'][\$i]['password'] = '${MYSQL_PASSWORD}';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
EOF

chmod -R 755 ./sites/phpmyadmin
chown -R 1000:1000 ./sites/phpmyadmin
cd ..

# Dedicated listener for port 8080 → phpMyAdmin only
echow "➤" "Creating port 8080 listener..."
cat > ./lsws/conf/listeners/phpmyadmin.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<listener>
  <name>phpmyadmin</name>
  <address>0.0.0.0:8080</address>
  <vHosts>Example</vHosts>
  <secure>0</secure>
</listener>
EOF

# phpMyAdmin context in Example VH
echow "➤" "Configuring context..."
mkdir -p ./lsws/conf/vhosts/Example
cat >> ./lsws/conf/vhosts/Example/vhconf.conf << 'EOF'

<context phpMyAdmin>
  <uri>/phpmyadmin</uri>
  <location>/var/www/vhosts/phpmyadmin</location>
  <type>static</type>
  <accessible>1</accessible>
  <indexFiles>index.php</indexFiles>
</context>
EOF

chmod 644 ./lsws/conf/listeners/phpmyadmin.xml
chmod 644 ./lsws/conf/vhosts/Example/vhconf.conf
chown 1000:1000 ./lsws/conf/listeners/phpmyadmin.xml ./lsws/conf/vhosts/Example/vhconf.conf 2>/dev/null || true

echow "➤" "Restarting LiteSpeed..."
docker compose restart litespeed
sleep 5

echow "✅" "phpMyAdmin ready on port 8080!"
echo "🌐 Access: http://localhost:8080/phpmyadmin/"
