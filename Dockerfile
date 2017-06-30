# Artifactory for OpenShift
#
# VERSION 		5.4.1epos

#official image name: eposcat/artifactory

FROM openjdk:8-jdk

# loosely based on existing repository https://github.com/fkirill/dockerfile-artifactory
MAINTAINER Daniel Zauner <daniel.zauner@epos-cat.de>

# To update, check https://bintray.com/jfrog/artifactory-pro/jfrog-artifactory-pro-zip/_latestVersion
# - ARTIFACTORY_USER: Must match settings in entrypoint-artifactory.sh
ENV \ 
  ARTIFACTORY_HOME=/var/opt/artifactory \ 
  ARTIFACTORY_DATA=/data/artifactory \ 
  DB_HOST=localhost \ 
  DB_PORT=5432 \ 
  DB_USER=artifactory \ 
  DB_PASSWORD=password \ 
  ARTIFACTORY_USER_ID=1030 \ 
  ARTIFACTORY_USER_NAME=artifactory \ 
  PS1="${debian_chroot:+($debian_chroot)}\\h:\\w\\$ "

# Expose tomcat runtime options through the RUNTIME_OPTS environment variable.
#   Example to set the JVM's max heap size to 256MB use the flag
#   '-e RUNTIME_OPTS="-Xmx256m"' when starting a container.
RUN echo 'export CATALINA_OPTS="$RUNTIME_OPTS"' > bin/setenv.sh

# Create Artifactory User
#RUN useradd -M -s /usr/sbin/nologin --uid ${ARTIFACTORY_USER_ID} --user-group ${ARTIFACTORY_USER_NAME}


# Create Artifactory home directory structure:
#  - access:  Subfolder for Access WAR
#  - etc:     Omitted as the stock etc will be moved over
#  - backup:  Backup folder
#  - data:    Data folder
#  - logs:    Log files
RUN \ 
  mkdir -p ${ARTIFACTORY_DATA} && \
  mkdir -p ${ARTIFACTORY_DATA}/access && \
  mkdir -p ${ARTIFACTORY_DATA}/backup && \
  mkdir -p ${ARTIFACTORY_DATA}/data && \
  mkdir -p ${ARTIFACTORY_DATA}/logs


# Fetch and install Artifactory Pro.
RUN \ 
  ARTIFACTORY_VERSION=5.4.2 \
  ARTIFACTORY_URL=https://bintray.com/jfrog/artifactory-pro/download_file?file_path=org/artifactory/pro/jfrog-artifactory-pro/${ARTIFACTORY_VERSION}/jfrog-artifactory-pro-${ARTIFACTORY_VERSION}.zip \
  ARTIFACTORY_SHA256=1b4de1058d99a1c861765a9cc5cf7541106cf953b61a30aca5e5b0c42201d14b \
  ARTIFACTORY_TEMP=$(mktemp -t "$(basename $0).XXXXXXXXXX.zip") && \
  curl -L -o ${ARTIFACTORY_TEMP} ${ARTIFACTORY_URL} && \
  printf '%s\t%s\n' $ARTIFACTORY_SHA256 $ARTIFACTORY_TEMP | sha256sum -c && \
  unzip $ARTIFACTORY_TEMP -d /tmp && \
  mv /tmp/artifactory-pro-${ARTIFACTORY_VERSION} ${ARTIFACTORY_HOME} && \
  find $ARTIFACTORY_HOME -type f -name "*.exe" -o -name "*.bat" | xargs /bin/rm && \
  rm -r $ARTIFACTORY_TEMP

# Grab PostgreSQL driver
RUN \ 
  POSTGRESQL_JAR_VERSION=9.4.1212 \
  POSTGRESQL_JAR=https://jdbc.postgresql.org/download/postgresql-${POSTGRESQL_JAR_VERSION}.jar && \
  curl -L -o $ARTIFACTORY_HOME/tomcat/lib/postgresql-${POSTGRESQL_JAR_VERSION}.jar ${POSTGRESQL_JAR}

# Link folders
# etc folder is copied over and linked back to preserve stock config
RUN \ 
  ln -s ${ARTIFACTORY_DATA}/access ${ARTIFACTORY_HOME}/access && \
  ln -s ${ARTIFACTORY_DATA}/backup ${ARTIFACTORY_HOME}/backup && \
  ln -s ${ARTIFACTORY_DATA}/data ${ARTIFACTORY_HOME}/data && \
  ln -s ${ARTIFACTORY_DATA}/logs ${ARTIFACTORY_HOME}/logs && \
  mv ${ARTIFACTORY_HOME}/etc ${ARTIFACTORY_DATA} && \
  ln -s ${ARTIFACTORY_DATA}/etc ${ARTIFACTORY_HOME}/etc

# setup PostgreSQL database
RUN \ 
  cp ${ARTIFACTORY_HOME}/misc/db/postgresql.properties ${ARTIFACTORY_DATA}/etc/db.properties && \ 
  sed -i "s|url=.*|url=jdbc:postgresql://$DB_HOST:$DB_PORT/artifactory|g" ${ARTIFACTORY_DATA}/etc/db.properties && \ 
  sed -i "s/username=.*/username=$DB_USER/g" ${ARTIFACTORY_DATA}/etc/db.properties && \ 
  sed -i "s/password=.*/password=$DB_PASSWORD/g" ${ARTIFACTORY_DATA}/etc/db.properties

# Change default port to 8080
RUN sed -i 's/port="8081"/port="8080"/' ${ARTIFACTORY_HOME}/tomcat/conf/server.xml

# Drop privileges
RUN \ 
  chown -R ${ARTIFACTORY_USER_ID}:${ARTIFACTORY_USER_ID} ${ARTIFACTORY_HOME} && \ 
  chmod -R 777 ${ARTIFACTORY_HOME} && \ 
  chown -R ${ARTIFACTORY_USER_ID}:${ARTIFACTORY_USER_ID} ${ARTIFACTORY_DATA} && \ 
  chmod -R 777 ${ARTIFACTORY_DATA}

USER $ARTIFACTORY_USER_ID

HEALTHCHECK --interval=5m --timeout=3s \
  CMD curl -f http://localhost:8080/artifactory || exit 1

# Expose Artifactories data directory
VOLUME ["/data/artifactory", "/data/artifactory/backup"]

WORKDIR /data/artifactory
SHELL ["/bin/bash"]

EXPOSE 8080

ENTRYPOINT ["/var/opt/artifactory/bin/artifactory.sh"]
