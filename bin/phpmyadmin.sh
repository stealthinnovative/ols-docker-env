#!/usr/bin/env bash
# phpmyadmin.sh - IDENTICAL wordpress.sh pattern
# 1. domain.sh → VHost   2. Files + .env creds   3. webadmin.sh restart

source .env
DOMAIN='phpmyadmin'
EPACE='        '

echow(){
    FLAG=${1}
    shift
    echo -e "\033[1m${EPACE}${FLAG}\033[0m${@}"
}

gen_root_fd(){
    if [ ! -d "./sites/${DOMAIN}" ]; then
        echo "Creating phpMyAdmin document root..."
        bash bin/domain.sh -add ${DOMAIN}
        echo "Finished - document root."
    else
        echo "[O] phpMyAdmin root folder ./sites/${DOMAIN}/ exists."
    fi
}

store_credential(){
    DOC_FD="./sites/${DOMAIN}/"
    cat > "${DOC_FD}/.db_pass" << EOT
{
"Database":"${MYSQL_DATABASE}",
"Username":"${MYSQL_USER}",
"Password":"${MYSQL_PASSWORD}"
}
EOT
}

phpmyadmin_download(){
    cd ./sites/${DOMAIN}
    
    # YOUR WORKING DOWNLOAD (use exact URL from your original script)
    wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz
    tar -xzf phpMyAdmin-5.2.3-all-languages.tar.gz --strip-components=1
    rm phpMyAdmin-5.2.3-all-languages.tar.gz
    
    # IDENTICAL config.inc.php → .env credentials (WordPress pattern)
    cat > config.inc.php << EOF
<?php
\$cfg['blowfish_secret'] = '$(openssl rand -base64 32)';
\$i = 0; \$i++;
\$cfg['Servers'][\$i]['host'] = 'mysql';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['user'] = '${MYSQL_USER}';
\$cfg['Servers'][\$i]['password'] = '${MYSQL_PASSWORD}';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
EOF
    
    chmod 644 config.inc.php
    cd ../..
}

lsws_restart(){
    bash bin/webadmin.sh -r
}

main(){
    gen_root_fd           # → domain.sh creates VHost (PROVEN)
    store_credential      # → .db_pass (WordPress identical)
    phpmyadmin_download   # → files + config.inc.php
    lsws_restart          # → graceful restart
    echow "🎉 phpMyAdmin ready! http://localhost:8080/"
    echow "   Login: ${MYSQL_USER} / ${MYSQL_PASSWORD}"
}

main "$@"
