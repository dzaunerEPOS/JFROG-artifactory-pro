#!/bin/bash
#
# An entrypoint script for Artifactory to allow custom setup before server starts
#

: ${ART_PRIMARY_BASE_URL:=http://artifactory-node1:8081/artifactory}
: ${ARTIFACTORY_USER_NAME:=artifactory}
: ${ARTIFACTORY_USER_ID:=1030}
: ${ARTIFACTORY_HOME:=/opt/jfrog/artifactory}
: ${ARTIFACTORY_DATA:=/var/opt/jfrog/artifactory}
ART_ETC=$ARTIFACTORY_DATA/etc
BOOTSTRAP_BUNDLE=${ART_ETC}/bootstrap.bundle.tar.gz

: ${ARTIFACTORY_EXTRA_CONF:=/artifactory_extra_conf}

: ${RECOMMENDED_MAX_OPEN_FILES:=32000}
: ${MIN_MAX_OPEN_FILES:=10000}

: ${RECOMMENDED_MAX_OPEN_PROCESSES:=1024}


logger() {
    DATE_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    if [ -z "$CONTEXT" ]
    then
        CONTEXT=$(caller)
    fi
    MESSAGE=$1
    CONTEXT_LINE=$(echo "$CONTEXT" | awk '{print $1}')
    CONTEXT_FILE=$(echo "$CONTEXT" | awk -F"/" '{print $NF}')
    printf "%s %05s %s %s\n" "$DATE_TIME" "[$CONTEXT_LINE" "$CONTEXT_FILE]" "$MESSAGE"
    CONTEXT=
}

errorExit () {
    logger "ERROR: $1"; echo
    exit 1
}

warn () {
    logger "WARNING: $1"
}

# Check the max open files and open processes set on the system
checkULimits () {
    logger "Checking open files and processes limits"

    CURRENT_MAX_OPEN_FILES=$(ulimit -n)
    logger "Current max open files is $CURRENT_MAX_OPEN_FILES"

    if [ ${CURRENT_MAX_OPEN_FILES} != "unlimited" ] && [ "$CURRENT_MAX_OPEN_FILES" -lt "$RECOMMENDED_MAX_OPEN_FILES" ]; then
        if [ "$CURRENT_MAX_OPEN_FILES" -lt "$MIN_MAX_OPEN_FILES" ]; then
            errorExit "Max number of open files $CURRENT_MAX_OPEN_FILES, is too low. Cannot run Artifactory!"
        fi

        warn "Max number of open files $CURRENT_MAX_OPEN_FILES is low!"
        warn "You should add the parameter '--ulimit nofile=${RECOMMENDED_MAX_OPEN_FILES}:${RECOMMENDED_MAX_OPEN_FILES}' to your the 'docker run' command."
    fi

    CURRENT_MAX_OPEN_PROCESSES=$(ulimit -u)
    logger "Current max open processes is $CURRENT_MAX_OPEN_PROCESSES"

    if [ "$CURRENT_MAX_OPEN_PROCESSES" != "unlimited" ] && [ "$CURRENT_MAX_OPEN_PROCESSES" -lt "$RECOMMENDED_MAX_OPEN_PROCESSES" ]; then
        warn "Max number of processes $CURRENT_MAX_OPEN_PROCESSES is too low!"
        warn "You should add the parameter '--ulimit noproc=${RECOMMENDED_MAX_OPEN_PROCESSES}:${RECOMMENDED_MAX_OPEN_PROCESSES}' to your the 'docker run' command."
    fi
}

# Check that data dir is mounted and warn if not
checkMounts () {
    logger "Checking if $ARTIFACTORY_DATA is mounted"
    mount | grep ${ARTIFACTORY_DATA} > /dev/null
    if [ $? -ne 0 ]; then
        warn "Artifactory data directory ($ARTIFACTORY_DATA) is not mounted from the host. This means that all data and configurations will be lost once container is removed!"
    else
        logger "$ARTIFACTORY_DATA is mounted"
    fi
}

# Add additional conf files that were mounted to ARTIFACTORY_EXTRA_CONF
addExtraConfFiles () {
    logger "Adding extra configuration files to ${ARTIFACTORY_HOME}/etc if any exist"

    # If directory not empty
    if [ -d "${ARTIFACTORY_EXTRA_CONF}" ] && [ "$(ls -A ${ARTIFACTORY_EXTRA_CONF})" ]; then
        logger "Adding files from ${ARTIFACTORY_EXTRA_CONF} to ${ARTIFACTORY_HOME}/etc"
        cp -rfv ${ARTIFACTORY_EXTRA_CONF}/* ${ARTIFACTORY_HOME}/etc || errorExit "Copy files from ${ARTIFACTORY_EXTRA_CONF} to ${ARTIFACTORY_HOME}/etc failed"
    fi
}

# In case data dirs are missing or not mounted, need to create them
setupDataDirs () {
    logger "Setting up data directories if missing"
    if [ ! -d ${ARTIFACTORY_DATA}/etc ]; then
        mkdir -p ${ARTIFACTORY_DATA}/etc errorExit "Failed creating $ARTIFACTORY_DATA/etc"

        # Add extra conf files to a newly created etc/ only!
        addExtraConfFiles
    fi
    [ -d ${ARTIFACTORY_DATA}/data ]   || mkdir -p ${ARTIFACTORY_DATA}/data   || errorExit "Failed creating $ARTIFACTORY_DATA/data"
    [ -d ${ARTIFACTORY_DATA}/logs ]   || mkdir -p ${ARTIFACTORY_DATA}/logs   || errorExit "Failed creating $ARTIFACTORY_DATA/logs"
    [ -d ${ARTIFACTORY_DATA}/backup ] || mkdir -p ${ARTIFACTORY_DATA}/backup || errorExit "Failed creating $ARTIFACTORY_DATA/backup"
    [ -d ${ARTIFACTORY_DATA}/access ] || mkdir -p ${ARTIFACTORY_DATA}/access || errorExit "Failed creating $ARTIFACTORY_DATA/access"
}

# Generate an artifactory.config.import.yml if parameters passed
# Only if artifactory.config.import.yml does not already exist!
prepareArtConfigYaml () {
    local artifactory_config_import_yml=${ARTIFACTORY_DATA}/etc/artifactory.config.import.yml
    if [ ! -f ${artifactory_config_import_yml} ]; then
        if [ -n "$AUTO_GEN_REPOS" ] || [ -n "$ART_BASE_URL" ] || [ -n "$ART_LICENSE" ]; then

            # Make sure license is provided (must be passed in Pro)
            if [ -z "$ART_LICENSE" ]; then
                errorExit "To use the feature of auto configuration, you must pass a valid Artifactory license as an ART_LICENSE environment variable!"
            fi

            logger "Generating ${artifactory_config_import_yml}"
            [ -n "$ART_LICENSE" ] && LIC_STR="licenseKey: $ART_LICENSE"
            [ -n "$ART_BASE_URL" ] && BASE_URL_STR="baseUrl: $ART_BASE_URL"
            [ -n "$AUTO_GEN_REPOS" ] && GEN_REPOS_STR="repoTypes:"

            cat <<EY1 > "$artifactory_config_import_yml"
version: 1
GeneralConfiguration:
  ${LIC_STR}
  ${BASE_URL_STR}
EY1

            if [ -n "$GEN_REPOS_STR" ]; then
                cat <<EY2 >> "$artifactory_config_import_yml"
OnboardingConfiguration:
  ${GEN_REPOS_STR}
EY2
                for repo in $(echo ${AUTO_GEN_REPOS} | tr ',' ' '); do
                    cat <<EY3 >> "$artifactory_config_import_yml"
   - ${repo}
EY3
                done
            fi
        fi
    fi
}

# Create the Artifactory user (support passing name and id as parameters)
setupArtUser () {
    logger "Create $ARTIFACTORY_USER_NAME user if missing"
    id -u ${ARTIFACTORY_USER_NAME} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        logger "User does not exist. Creating it..."
        useradd -M -s /usr/sbin/nologin --uid ${ARTIFACTORY_USER_ID} --user-group ${ARTIFACTORY_USER_NAME} || errorExit "Creating user $ARTIFACTORY_USER_NAME failed"
    else
        logger "User $ARTIFACTORY_USER_NAME already exists"
    fi
}

# Do the actual permission check and chown
checkAndSetOwnerOnDir () {
    local DIR_TO_CHECK=$1
    local USER_TO_CHECK=$2
    local GROUP_TO_CHECK=$3

    logger "Checking permissions on $DIR_TO_CHECK"
    local STAT=( $(stat -Lc "%U %G" ${DIR_TO_CHECK}) )
    local USER=${STAT[0]}
    local GROUP=${STAT[1]}

    if [[ ${USER} != "$USER_TO_CHECK" ]] || [[ ${GROUP} != "$GROUP_TO_CHECK"  ]] ; then
        logger "$DIR_TO_CHECK is owned by $USER:$GROUP. Setting to $USER_TO_CHECK:$GROUP_TO_CHECK."
        chown -R ${USER_TO_CHECK}:${GROUP_TO_CHECK} ${DIR_TO_CHECK} || errorExit "Setting ownership on $DIR_TO_CHECK failed"
    else
        logger "$DIR_TO_CHECK is already owned by $USER_TO_CHECK:$GROUP_TO_CHECK."
    fi
}

# Check and set permissions on ARTIFACTORY_HOME and ARTIFACTORY_DATA
setupPermissions () {
    # ARTIFACTORY_HOME
    checkAndSetOwnerOnDir $ARTIFACTORY_HOME $ARTIFACTORY_USER_NAME $ARTIFACTORY_USER_NAME

    # ARTIFACTORY_DATA
    checkAndSetOwnerOnDir $ARTIFACTORY_DATA $ARTIFACTORY_USER_NAME $ARTIFACTORY_USER_NAME

    # HA_DATA_DIR (If running in HA mode)
    if [ -d "$HA_DATA_DIR" ]; then
        checkAndSetOwnerOnDir $HA_DATA_DIR $ARTIFACTORY_USER_NAME $ARTIFACTORY_USER_NAME
    fi

    # HA_BACKUP_DIR (If running in HA mode)
    if [ -d "$HA_BACKUP_DIR" ]; then
        checkAndSetOwnerOnDir $HA_BACKUP_DIR $ARTIFACTORY_USER_NAME $ARTIFACTORY_USER_NAME
    fi
}

# Wait for primary node if needed
waitForPrimaryNode () {
    logger "Waiting for primary node to be up"

    local CMD="curl --silent --fail $ART_PRIMARY_BASE_URL/api/system/ping"
    logger "Running $CMD"
    while [ "$($CMD)" != "OK" ]; do
        logger "."
        sleep 4
    done

    logger "Primary node ($ART_PRIMARY_BASE_URL) is up!"
}

# Wait for existence of etc/bootstrap.bundle.tar.gz
waitForBootstrapBundle () {
    logger "Waiting for $BOOTSTRAP_BUNDLE"

    while [ ! -f ${BOOTSTRAP_BUNDLE} ]; do
        logger "."
        sleep 4
    done
    logger "$BOOTSTRAP_BUNDLE exists! Setting ${ARTIFACTORY_USER_NAME} as owner"

    # Make sure file is owned by artifactory
    chown ${ARTIFACTORY_USER_NAME}:${ARTIFACTORY_USER_NAME} ${BOOTSTRAP_BUNDLE} || errorExit "Setting owner of ${BOOTSTRAP_BUNDLE} to ${ARTIFACTORY_USER_NAME} failed"
}

# Wait for DB port to be accessible
waitForDB () {
    local PROPS_FILE=$1
    local DB_TYPE=$2

    [ -f "$PROPS_FILE" ] || errorExit "$PROPS_FILE does not exist"

    local DB_HOST_PORT=
    local TIMEOUT=30
    local COUNTER=0

    # Extract DB host and port
    case "$DB_TYPE" in
        postgresql|mysql)
            DB_HOST_PORT=$(grep -e '^url=' "$PROPS_FILE" | sed -e 's,^.*:\/\/\(.*\)\/.*,\1,g' | tr ':' '/')
        ;;
        oracle)
            DB_HOST_PORT=$(grep -e '^url=' "$PROPS_FILE" | sed -e 's,.*@\(.*\):.*,\1,g' | tr ':' '/')
        ;;
        mssql)
            DB_HOST_PORT=$(grep -e '^url=' "$PROPS_FILE" | sed -e 's,^.*:\/\/\(.*\);databaseName.*,\1,g' | tr ':' '/')
        ;;
        *)
            errorExit "DB_TYPE $DB_TYPE not supported"
        ;;
    esac

    logger "Waiting for DB $DB_TYPE to be ready on $DB_HOST_PORT within $TIMEOUT seconds"

    while [ $COUNTER -lt $TIMEOUT ]; do
        (</dev/tcp/$DB_HOST_PORT) 2>/dev/null
        if [ $? -eq 0 ]; then
            logger "DB $DB_TYPE up in $COUNTER seconds"
            return 1
        else
            logger "."
            sleep 1
        fi
        let COUNTER=$COUNTER+1
    done

    return 0
}

# Set and configure DB type
checkHA () {
    # Check if HA (if one HA_XXX is set)
    if [ -n "$HA_NODE_ID" ] || [ -n "$HA_IS_PRIMARY" ]; then
        logger "Detected an Artifactory HA setup"
        if [ -z "$HA_NODE_ID" ]; then
            logger "HA_NODE_ID not set. Generating"
            HA_NODE_ID="node-$(hostname)"
            logger "HA_NODE_ID set to $HA_NODE_ID"
        fi
        if [ -z "$HA_IS_PRIMARY" ]; then
            errorExit "To setup Artifactory HA, you must set the HA_IS_PRIMARY environment variable"
        fi
        if [ -z "$HA_DATA_DIR" ]; then
            warn "HA_DATA_DIR is not set, Artifactory will use local data folder"
            HA_DATA_DIR="$ARTIFACTORY_DATA/data"
        fi
        if [ -z "$HA_BACKUP_DIR" ]; then
            warn "HA_BACKUP_DIR is not set, Artifactory will use local backup folder"
            HA_BACKUP_DIR="$ARTIFACTORY_DATA/backup"
        fi
        if [ -z "$HA_MEMBERSHIP_PORT" ]; then
            HA_MEMBERSHIP_PORT=10002
        fi

        # Get the container's internal IP to be used for ha-node.properties
        HA_HOST_IP=$(hostname -i)
        logger "HA_HOST_IP is set to $HA_HOST_IP"

        if [ -z "$HA_CONTEXT_URL" ]; then
            warn "HA_CONTEXT_URL is missing, using HA_HOST_IP as context url"
            HA_CONTEXT_URL=http://$HA_HOST_IP:8081/artifactory
        fi

        # If this is not the primary node, make sure the primary node's URL is passed and wait for it before proceeding
        if [[ $HA_IS_PRIMARY =~ false ]]; then
            logger "This is not the primary node. Must wait for primary node before starting"
            waitForPrimaryNode
        fi

        # Wait for etc/bootstrap.bundle.tar.gz (only on non-primary nodes)
        if [[ $HA_IS_PRIMARY =~ false ]] && [ "$HA_WAIT_FOR_BUNDLE" == "true" ]; then
            logger "HA_WAIT_FOR_BUNDLE set. Waiting for ${BOOTSTRAP_BUNDLE} existence"
            waitForBootstrapBundle
        fi

        # (If no etc/bootstrap.bundle.tar.gz)
        # Setup the security communication key
        # Due to a limitation with setting permissions on mounted volumes in Mac OS
        # Putting it in a local directory and linking to it
        if [ ! -f ${BOOTSTRAP_BUNDLE} ]; then
            if [ ! -d  "$ART_ETC/security" ]; then
                logger "$ART_ETC/security does not exist. Creating it"
                mkdir -p "$ART_ETC/security" || errorExit "Creating $ART_ETC/security directory failed"

                # If a key file exists in $ARTIFACTORY_DATA/communication.key, use it (good for demos)
                if [ -f $ARTIFACTORY_DATA/communication.key ]; then
                    logger "Found $ARTIFACTORY_DATA/communication.key. Using it..."
                    cp -v $ARTIFACTORY_DATA/communication.key $ART_ETC/security/ || errorExit "Copying $ARTIFACTORY_DATA/communication.key to $ART_ETC/security failed"
                    chmod 600 "$ART_ETC/security/communication.key" || errorExit "Changing mode for $ART_ETC/security/communication.key file failed"
                fi

                chown -R ${ARTIFACTORY_USER_NAME}: "$ART_ETC/security" || errorExit "Change owner of $ART_ETC/security to ${ARTIFACTORY_USER_NAME} failed"
            fi
        else
            logger "$BOOTSTRAP_BUNDLE exists. Skipping communication.key setup"
        fi

        # Install license file if exists in /tmp
        if ls /tmp/art*.lic 1> /dev/null 2>&1; then
            logger "Found /tmp/art*.lic. Using it..."
            cp -v /tmp/art*.lic $ART_ETC/artifactory.lic
            chown -R ${ARTIFACTORY_USER_NAME}: $ART_ETC/artifactory.lic || errorExit "Change owner of $ART_ETC/artifactory.lic to ${ARTIFACTORY_USER_NAME} failed"
        fi

        # Start preparing the HA setup if not already exists
        if [ ! -f "$ART_ETC/ha-node.properties" ]; then
            logger "Preparing $ART_ETC/ha-node.properties"
            cat <<EOF > "$ART_ETC/ha-node.properties"
node.id=$HA_NODE_ID
context.url=$HA_CONTEXT_URL
membership.port=$HA_MEMBERSHIP_PORT
primary=$HA_IS_PRIMARY
hazelcast.interface=$HA_HOST_IP
EOF
            if [ -n "$HA_DATA_DIR" ] && [ -n "$HA_BACKUP_DIR" ] ; then
                echo "artifactory.ha.data.dir=$HA_DATA_DIR" >> "$ART_ETC/ha-node.properties"
                echo "artifactory.ha.backup.dir=$HA_BACKUP_DIR" >> "$ART_ETC/ha-node.properties"
            fi

            chown ${ARTIFACTORY_USER_NAME}: $ART_ETC/ha-node.properties || errorExit "Change owner of $ART_ETC/ha-node.properties to ${ARTIFACTORY_USER_NAME} failed"
        else
            # Update existing for the case the IP changed
            logger "$ART_ETC/ha-node.properties already exists. Making sure properties with IP are updated correctly"
            sed -i "s,^context.url=.*,context.url=$HA_CONTEXT_URL,g" $ART_ETC/ha-node.properties || errorExit "Updating $ART_ETC/ha-node.properties with context.url failed"
            sed -i "s,^hazelcast.interface=.*,hazelcast.interface=$HA_HOST_IP,g" $ART_ETC/ha-node.properties || errorExit "Updating $ART_ETC/ha-node.properties with hazelcast.interface failed"
        fi
        logger "Content of $ART_ETC/ha-node.properties:"
        cat $ART_ETC/ha-node.properties; echo
    fi
}

# Check DB type configurations before starting Artifactory
setDBConf () {
    # If bootstrap bundle exists, skip this
    if [ ! -f ${BOOTSTRAP_BUNDLE} ]; then
        # Set default DB_HOST
        if [ -z "$DB_HOST" ]; then
            DB_HOST=$DB_TYPE
        fi

        logger "Checking if need to copy $DB_TYPE configuration"
        # If already exists, just make sure it's configured for postgres
        if [ -f ${DB_PROPS} ]; then
            logger "${DB_PROPS} already exists. Making sure it's set to $DB_TYPE... "
            grep type=$DB_TYPE ${DB_PROPS} > /dev/null
            if [ $? -eq 0 ]; then
                logger "${DB_PROPS} already set to $DB_TYPE"
            else
                errorExit "${DB_PROPS} already exists and is set to a DB different than $DB_TYPE"
            fi
        else
            NEED_COPY=true
        fi

        # On a new install and startup, need to make the initial copy before Artifactory starts
        if [ "$NEED_COPY" == "true" ]; then
            logger "Copying $DB_TYPE configuration... "
            cp ${ARTIFACTORY_HOME}/misc/db/$DB_TYPE.properties ${DB_PROPS} || errorExit "Copying $ARTIFACTORY_HOME/misc/db/$DB_TYPE.properties to ${DB_PROPS} failed"
            chown ${ARTIFACTORY_USER_NAME}: ${DB_PROPS} || errorExit "Change owner of ${DB_PROPS} to ${ARTIFACTORY_USER_NAME} failed"

            sed -i "s/localhost/$DB_HOST/g" ${DB_PROPS}

            # Set custom DB parameters if specified
            if [ ! -z "$DB_USER" ]; then
                logger "Setting DB_USER to $DB_USER"
                sed -i "s/username=.*/username=$DB_USER/g" ${DB_PROPS}
            fi
            if [ ! -z "$DB_PASSWORD" ]; then
                logger "Setting DB_PASSWORD to **********"
                sed -i "s/password=.*/password=$DB_PASSWORD/g" ${DB_PROPS}
            fi

            # Set the URL depending on what parameters are passed
            if [ ! -z "$DB_URL" ]; then
                logger "Setting DB_URL to $DB_URL (ignoring DB_HOST and DB_PORT if set)"
                # Escape any & signs (so sed will not get messed up)
                DB_URL=$(echo -n ${DB_URL} | sed "s|&|\\\\&|g")
                sed -i "s|url=.*|url=$DB_URL|g" ${DB_PROPS}
            else
                if [ ! -z "$DB_PORT" ]; then
                    logger "Setting DB_PORT to $DB_PORT"
                    case "$DB_TYPE" in
                        mysql|postgresql)
                            oldPort=$(grep -E "(url).*" ${DB_PROPS}  | awk -F":" '{print $4}' | awk -F"/" '{print $1}')
                        ;;
                        oracle)
                            oldPort=$(grep -E "(url).*" ${DB_PROPS} | awk -F":" '{print $5}')
                        ;;
                        mssql)
                            oldPort=$(grep -E "(url).*" ${DB_PROPS}  | awk -F":" '{print $4}' | awk -F";" '{print $1}')
                        ;;
                    esac

                    sed -i "s/$oldPort/$DB_PORT/g" ${DB_PROPS}
                fi
                if [ ! -z "$DB_HOST" ]; then
                    logger "Setting DB_HOST to $DB_HOST"
                    case "$DB_TYPE" in
                        mysql|postgresql|mssql)
                            oldHost=$(grep -E "(url).*" ${DB_PROPS} | awk -F"//" '{print $2}' | awk -F":" '{print $1}')
                        ;;
                        oracle)
                            oldHost=$(grep -E "(url).*" ${DB_PROPS} | awk -F"@" '{print $2}' | awk -F":" '{print $1}')
                        ;;
                    esac

                    sed -i "s/$oldHost/$DB_HOST/g" ${DB_PROPS}
                fi
            fi
        fi
    else
        logger "$BOOTSTRAP_BUNDLE exists. Skipping db.properties setup"
    fi
}

# Set and configure DB type
setDBType () {
    logger "Checking DB_TYPE"

    if [ ! -z "$DB_TYPE" ]; then
        logger "DB_TYPE is set to $DB_TYPE"
        NEED_COPY=false
        DB_PROPS=${ART_ETC}/db.properties

        case "$DB_TYPE" in
            postgresql)
                if ! ls $ARTIFACTORY_HOME/tomcat/lib/postgresql-*.jar 1> /dev/null 2>&1; then
                    errorExit "No postgresql connector found"
                fi
                setDBConf
            ;;
            mysql)
                if ! ls $ARTIFACTORY_HOME/tomcat/lib/mysql-connector-java*.jar 1> /dev/null 2>&1; then
                    errorExit "No mysql connector found"
                fi
                setDBConf
            ;;
            oracle)
                if ! ls $ARTIFACTORY_HOME/tomcat/lib/ojdb*.jar 1> /dev/null 2>&1; then
                    errorExit "No oracle ojdbc driver found"
                fi
                setDBConf
            ;;
            mssql)
                if ! ls $ARTIFACTORY_HOME/tomcat/lib/sqljdbc*.jar 1> /dev/null 2>&1; then
                    errorExit "No mssql connector found"
                fi
                setDBConf
            ;;
            *)
                errorExit "DB_TYPE $DB_TYPE not supported"
            ;;
        esac

        # Wait for DB
        # On slow systems, when working with docker-compose, the DB container might be up,
        # but not ready to accept connections when Artifactory is already trying to access it.
        if [[ ! "$HA_IS_PRIMARY" =~ false ]]; then
            waitForDB "$DB_PROPS" "$DB_TYPE"
            [ $? -eq 1 ] || errorExit "DB $DB_TYPE failed to start in the given time"
        fi
    else
        logger "DB_TYPE not set. Artifactory will use built in Derby DB"
    fi
}

addExtraJavaArgs () {
    logger "Adding EXTRA_JAVA_OPTIONS if exist"
    if [ ! -z "$EXTRA_JAVA_OPTIONS" ] && [ ! -f ${ARTIFACTORY_HOME}/bin/artifactory.default.origin ]; then
        logger "Adding EXTRA_JAVA_OPTIONS $EXTRA_JAVA_OPTIONS"
        cp -v ${ARTIFACTORY_HOME}/bin/artifactory.default ${ARTIFACTORY_HOME}/bin/artifactory.default.origin
        echo "export JAVA_OPTIONS=\"\$JAVA_OPTIONS $EXTRA_JAVA_OPTIONS\"" >> ${ARTIFACTORY_HOME}/bin/artifactory.default
    fi
}

addPlugins () {
    logger "Adding plugins if exist"
    mkdir -p ${ARTIFACTORY_HOME}/etc/plugins || errorExit "Failed creating ${ARTIFACTORY_HOME}/etc/plugins"
    mv -fv /tmp/plugins/* ${ARTIFACTORY_HOME}/etc/plugins/
}

######### Main #########

echo; echo "Preparing to run Artifactory in Docker"
echo "====================================="

checkULimits
checkMounts
setupDataDirs
prepareArtConfigYaml
setupArtUser
addPlugins
setupPermissions
checkHA
setDBType
addExtraJavaArgs

echo; echo "====================================="; echo

# Run Artifactory as ARTIFACTORY_USER_NAME user
exec gosu ${ARTIFACTORY_USER_NAME} ${ARTIFACTORY_HOME}/bin/artifactory.sh
