#!/usr/bin/env bash
# Load our optimized .env variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env file not found! Please create it first."
    exit 1
fi

APP_NAME='wordpress'
CONT_NAME='litespeed'
DOC_FD=''

# --- Formatting Helpers ---
echow(){
    FLAG=${1}
    shift
    echo -e "\033[1m  ${FLAG}\033[0m ${@}"
}

# --- Validation & Domain Cleaning ---
domain_filter(){
    if [ -z "${DOMAIN}" ]; then
        echo "No DOMAIN found in .env. Please check your settings."
        exit 1
    fi
    # Filter protocols and paths to get raw domain
    DOMAIN_RAW="${DOMAIN#http://}"
    DOMAIN_RAW="${DOMAIN_RAW#https://}"
    DOMAIN_RAW=${DOMAIN_RAW%%/*}
}

# --- Step 1: Document Root ---
gen_root_fd(){
    DOC_FD="./sites/${1}/"
    if [ -d "./sites/${1}" ]; then
        echow "[O]" "The root folder ${DOC_FD} exists."
    else
        echow "[+]" "Creating document root via domain.sh..."
        bash bin/domain.sh -add "${1}"
    fi
}

# --- Step 2: Database Creation ---
create_db(){
    echow "[+]" "Provisioning MariaDB database..."
    bash bin/database.sh -D "${1}" -U "${MYSQL_USER}" -P "${MYSQL_PASSWORD}" -DB "${MYSQL_DATABASE}"
}

# --- Step 3: WordPress Install (The Core) ---
app_download(){
    echow "[+]" "Running OLS App Installer for ${1}..."
    # We pass PHP_VER to ensure the installer links the site to the correct PHP engine
    docker compose exec -T ${CONT_NAME} su -c "appinstallctl.sh --app ${1} --domain ${2}"
}

lsws_restart(){
    echow "[+]" "Graceful restart of OpenLiteSpeed..."
    bash bin/webadmin.sh -r
}

main(){
    domain_filter
    gen_root_fd "${DOMAIN_RAW}"
    create_db "${DOMAIN_RAW}"
    app_download "${APP_NAME}" "${DOMAIN_RAW}"
    lsws_restart
    echow "[SUCCESS]" "Your Ryzen-optimized WordPress site is ready at https://${DOMAIN_RAW}"
}

# --- Execution ---
case ${1} in
    -[hH] | -help | --help)
        echow "HELP:" "This script uses your .env settings to auto-provision OLS + WordPress."
        exit 0
        ;;
    *)
        main
        ;;
esac