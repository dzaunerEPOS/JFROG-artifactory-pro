#!/bin/bash
#
# An entrypoint script for Artifactory to allow custom setup before server starts
#

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

######### Main #########

echo; echo "Preparing to run Artifactory in Docker"
echo "====================================="

checkULimits
setDBType

echo; echo "====================================="; echo

# Run Artifactory as ARTIFACTORY_USER_NAME user
exec gosu ${ARTIFACTORY_USER_NAME} ${ARTIFACTORY_HOME}/bin/artifactory.sh
