#!/bin/bash
#
# An entrypoint script for Artifactory to allow custom setup before server starts
#

ART_ETC=$ARTIFACTORY_DATA/etc

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

# In case data dirs are missing or not mounted, need to create them
setupDataDirs () {
    logger "Setting up data directories if missing"
    if [ ! -d ${ARTIFACTORY_DATA}/etc ]; then
        mv ${ARTIFACTORY_HOME}/etc-clean ${ARTIFACTORY_DATA}/etc || errorExit "Failed creating $ARTIFACTORY_DATA/data"
    fi
    [ -d ${ARTIFACTORY_DATA}/data ]   || mkdir -p ${ARTIFACTORY_DATA}/data   || errorExit "Failed creating $ARTIFACTORY_DATA/data"
    [ -d ${ARTIFACTORY_DATA}/logs ]   || mkdir -p ${ARTIFACTORY_DATA}/logs   || errorExit "Failed creating $ARTIFACTORY_DATA/logs"
    [ -d ${ARTIFACTORY_DATA}/backup ] || mkdir -p ${ARTIFACTORY_DATA}/backup || errorExit "Failed creating $ARTIFACTORY_DATA/backup"
    [ -d ${ARTIFACTORY_DATA}/access ] || mkdir -p ${ARTIFACTORY_DATA}/access || errorExit "Failed creating $ARTIFACTORY_DATA/access"
}

# Wait for DB port to be accessible
waitForDB () {
    local PROPS_FILE=$1

    [ -f "$PROPS_FILE" ] || errorExit "$PROPS_FILE does not exist"

    local DB_HOST_PORT=
    local TIMEOUT=30
    local COUNTER=0

    # Extract DB host and port
    DB_HOST_PORT=$(grep -e '^url=' "$PROPS_FILE" | sed -e 's,^.*:\/\/\(.*\)\/.*,\1,g' | tr ':' '/')

    logger "Waiting for PostgreSQL to be ready on $DB_HOST_PORT within $TIMEOUT seconds"

    while [ $COUNTER -lt $TIMEOUT ]; do
        (</dev/tcp/$DB_HOST_PORT) 2>/dev/null
        if [ $? -eq 0 ]; then
            logger "PostgreSQL up in $COUNTER seconds"
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
	logger "Generating ${DB_PROPS}"
  cat <<EOF > ${DB_PROPS}
type=postgresql
driver=org.postgresql.Driver
url=jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME
username=$DB_USER
password=$DB_PASSWORD
EOF
}

# Set and configure DB type
setDBType () {
	NEED_COPY=false
	DB_PROPS=${ART_ETC}/db.properties

	if ! ls $ARTIFACTORY_HOME/tomcat/lib/postgresql-*.jar 1> /dev/null 2>&1; then
		errorExit "No postgresql connector found"
	fi
	setDBConf


	# Wait for DB
	# On slow systems, when working with docker-compose, the DB container might be up,
	# but not ready to accept connections when Artifactory is already trying to access it.
	waitForDB "$DB_PROPS"
	[ $? -eq 1 ] || errorExit "PostgreSQL failed to start in the given time"
}

# wait until .lock file is closed if it isn't
checkLockFile () {
    local TIMEOUT=30
    local COUNTER=0
    local LOCK_FILE=${ARTIFACTORY_DATA}/data/.lock

	if [ -e $LOCK_FILE ]; then
		logger "Found .lock file from previous instance, trying delete"
		while ! rm $LOCK_FILE > /dev/null; do
			logger "."
			sleep 1
			let COUNTER=$COUNTER+1
			if [ $COUNTER -gt $TIMEOUT ]; then
				errorExit "Couldn't delete .lock file"
			fi
		done
	fi
}

setJvmHeapSize() {
	BYTES_PER_MEG=$((1024*1024))
	BYTES_PER_GIG=$((1024*${BYTES_PER_MEG}))

	MIN_MEMORY_BYTES=$((1024*${BYTES_PER_MEG}))

	logger "Setting Xmx and Xms memory based on provided HEAP_SIZE environment variable value: ${HEAP_SIZE}"
	regex='^([[:digit:]]+)([GgMm])i?$'
	if [[ "${HEAP_SIZE:-}" =~ $regex ]]; then
		num=${BASH_REMATCH[1]}
		unit=${BASH_REMATCH[2]}
		if [[ $unit =~ [Gg] ]]; then
			((num = num * ${BYTES_PER_GIG})) # enables math to work out for odd Gi
		elif [[ $unit =~ [Mm] ]]; then
			((num = num * ${BYTES_PER_MEG})) # enables math to work out for odd Mi
		fi

		logger "Inspecting the maximum RAM available..."

		container_mem_file="/sys/fs/cgroup/memory/memory.limit_in_bytes"
		node_mem_file="/proc/meminfo"
		if [ -r "${container_mem_file}" ] && [ -r "${node_mem_file}" ]; then
			container_mem=$(cat $container_mem_file)
			node_mem=$(cat $node_mem_file | grep MemAvailable | awk '{print $2 * 1024}')
			if [ ${container_mem} -lt ${node_mem} ]; then
				avail_mem=${container_mem}
			else
				avail_mem=${node_mem}
			fi

			if [ ${avail_mem} -lt ${num} ]; then
				((num = ${avail_mem}))
				logger "Setting the heap size to $(($num / BYTES_PER_MEG))m which is the largest amount available in this container."
			fi
		else
			logger "Unable to determine the maximum allowable RAM for this container's cgroup or node."
			exit 1
		fi

		if [[ $num -lt $MIN_MEMORY_BYTES ]]; then
			logger "A minimum of $(($MIN_MEMORY_BYTES / $BYTES_PER_MEG))m heap size is required but only $(($num / $BYTES_PER_MEG))m is available or was specified."
			exit 1
		fi

		logger "The heap size will now be set to $(($num * 100 / avail_mem))% of the currently available memory."

		# set value in artifactory.default
		sed -i -r "s/export JAVA_OPTIONS=\"(.*?)-Xms[0-9]+[GgMm]i? -Xmx[0-9]+[GgMm]i? (.*)/export JAVA_OPTIONS=\"\1-Xms2G -Xmx2G \2/" ${ARTIFACTORY_HOME}/bin/artifactory.default

	else
		logger "HEAP_SIZE environment variable not set or invalid: ${HEAP_SIZE:-}"
		logger "Keeping default standard values. Set HEAP_SIZE for increased performance."
	fi
}

start() {
  createLogsLink
  . $ARTIFACTORY_HOME/bin/artifactory.default || errorArtHome "ERROR: Defaults file does not exist or not executable"
  export CATALINA_OPTS="$JAVA_OPTIONS -Dartifactory.home=$ARTIFACTORY_HOME -Dfile.encoding=UTF8 -Djruby.compile.invokedynamic=false -Djfrog.access.bundled=true"
  export CATALINA_PID="$ARTIFACTORY_PID"
  [ -x $TOMCAT_HOME/bin/catalina.sh ] || chmod +x $TOMCAT_HOME/bin/*.sh
  if [ -z "$@" ];
  then
    #default to catalina.sh run
    exec $TOMCAT_HOME/bin/catalina.sh run
  else
    exec $TOMCAT_HOME/bin/catalina.sh "$@"
  fi
}
createLogsLink() {
    mkdir -p $ARTIFACTORY_HOME/logs/catalina || errorArtHome "Could not create dir $ARTIFACTORY_HOME/logs/catalina"
    if [ ! -L "$TOMCAT_HOME/logs" ];
    then
        ln -s $ARTIFACTORY_HOME/logs/catalina $TOMCAT_HOME/logs || \
            errorArtHome "Could not create link from $TOMCAT_HOME/logs to $ARTIFACTORY_HOME/logs/catalina"
    fi
}

######### Main #########

echo; echo "Preparing to run Artifactory in Docker"
echo "====================================="

checkULimits
checkMounts
setupDataDirs
setDBType
checkLockFile
setJvmHeapSize

echo; echo "====================================="; echo

start "$@"
# Run Artifactory as ARTIFACTORY_USER_NAME user
#exec ${ARTIFACTORY_HOME}/bin/artifactory.sh start
