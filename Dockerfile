# Artifactory for OpenShift
#
# VERSION 		5.4.1epos

#official image name: eposcat/artifactory

FROM tomcat:8-jre8

# loosely based on existing repository https://github.com/fkirill/dockerfile-artifactory
MAINTAINER Daniel Zauner <daniel.zauner@epos-cat.de>

# To update, check https://bintray.com/jfrog/artifactory-pro/jfrog-artifactory-pro-zip/_latestVersion
ENV ARTIFACTORY_VERSION 5.4.1
ENV ARTIFACTORY_SHA1 bd08d6dc83b4d987f36e53bf727baa68da946aff0ca4c286dccb7fcaec0faf76
ENV ARTIFACTORY_URL https://bintray.com/jfrog/artifactory-pro/download_file?file_path=org/artifactory/pro/jfrog-artifactory-pro/${ARTIFACTORY_VERSION}/jfrog-artifactory-pro-${ARTIFACTORY_VERSION}.zip

ENV POSTGRESQL_JAR_VERSION 9.4.1212
ENV POSTGRESQL_JAR https://jdbc.postgresql.org/download/postgresql-${POSTGRESQL_JAR_VERSION}.jar

ENV ARTIFACTORY_HOME /var/opt/artifactory
ENV ARTIFACTORY_DATA /data/artifactory
ENV DB_TYPE postgresql
ENV DB_USER artifactory
ENV DB_PASSWORD password

# Must match settings in entrypoint-artifactory.sh
ENV ARTIFACTORY_USER_ID 1030
ENV ARTIFACTORY_USER_NAME artifactory
ENV ARTIFACTORY_PID ${ARTIFACTORY_HOME}/run/artifactory.pid

# Disable Tomcat's manager application.
RUN rm -rf /usr/local/tomcat/webapps/*

# Expose tomcat runtime options through the RUNTIME_OPTS environment variable.
#   Example to set the JVM's max heap size to 256MB use the flag
#   '-e RUNTIME_OPTS="-Xmx256m"' when starting a container.
RUN echo 'export CATALINA_OPTS="$RUNTIME_OPTS"' > bin/setenv.sh

# Create Artifactory User
RUN useradd -M -s /usr/sbin/nologin --uid ${ARTIFACTORY_USER_ID} --user-group ${ARTIFACTORY_USER_NAME}

# Create Artifactory home directory structure:
#  - access:  Subfolder for Access WAR
#  - etc:     Omitted as the stock etc will be moved over
#  - backup:  Backup folder
#  - data:    Data folder
#  - logs:    Log files
RUN mkdir -p ${ARTIFACTORY_DATA} && \
 mkdir -p ${ARTIFACTORY_DATA}/access && \
 mkdir -p ${ARTIFACTORY_DATA}/backup && \
 mkdir -p ${ARTIFACTORY_DATA}/data && \
 mkdir -p ${ARTIFACTORY_DATA}/logs


# Fetch and install Artifactory Pro.
RUN \
  curl -L# -o /tmp/artifactory.zip ${ARTIFACTORY_URL} && \
  unzip /tmp/artifactory.zip -d /tmp && \
  mv /tmp/artifactory-pro-${ARTIFACTORY_VERSION} ${ARTIFACTORY_HOME} && \
  find $ARTIFACTORY_HOME -type f -name "*.exe" -o -name "*.bat" | xargs /bin/rm && \
  rm -r /tmp/artifactory.zip

# Grab PostgreSQL driver
RUN curl -L# -o $ARTIFACTORY_HOME/tomcat/lib/postgresql-${POSTGRESQL_JAR_VERSION}.jar ${POSTGRESQL_JAR}

# Link folders
RUN \
  ln -s ${ARTIFACTORY_DATA}/access ${ARTIFACTORY_HOME}/access && \
  ln -s ${ARTIFACTORY_DATA}/backup ${ARTIFACTORY_HOME}/backup && \
  ln -s ${ARTIFACTORY_DATA}/data ${ARTIFACTORY_DATA}/data && \
  ln -s ${ARTIFACTORY_DATA}/logs ${ARTIFACTORY_DATA}/logs && \
  mv ${ARTIFACTORY_HOME}/etc ${ARTIFACTORY_DATA} && \
  ln -s ${ARTIFACTORY_DATA}/etc ${ARTIFACTORY_DATA}/etc

# Deploy Entry Point
COPY files/entrypoint-artifactory.sh / 
# Entry-Point Fixups:
# - Disable permissions check (assume correct)
# - Prevent entryfile from chown'ing around like crazy...
# - Fix Windows linebreaks (entrypoint may contain them...)
# - Remove 'gosu' instruction as OpenShift forces unprivileged anyway
RUN \
  sed -i 's/^\(setupPermissions\)$/#\1/m' /entrypoint-artifactory.sh && \
  sed -i 's/chown/#chown/' /entrypoint-artifactory.sh && \
  sed -i 's/\r//' /entrypoint-artifactory.sh && \
  sed -i 's/gosu \${ARTIFACTORY_USER_NAME}//' /entrypoint-artifactory.sh

# Change default port to 8080
RUN sed -i 's/port="8081"/port="8080"/' ${ARTIFACTORY_HOME}/tomcat/conf/server.xml

# Drop privileges
RUN \
  chown -R ${ARTIFACTORY_USER_NAME}:${ARTIFACTORY_USER_NAME} ${ARTIFACTORY_HOME} && \
  chmod -R 777 ${ARTIFACTORY_HOME} && \
  chown -R ${ARTIFACTORY_USER_NAME}:${ARTIFACTORY_USER_NAME} ${ARTIFACTORY_DATA} && \
  chmod -R 777 ${ARTIFACTORY_DATA} && \
  chmod a+x /entrypoint-artifactory.sh


USER $ARTIFACTORY_USER_ID
HEALTHCHECK --interval=5m --timeout=3s \
  CMD curl -f http://localhost:8080/artifactory || exit 1

# Expose Artifactories data directory
VOLUME ["/data/artifactory", "/data/artifactory/backup"]

WORKDIR /data/artifactory

EXPOSE 8080

ENTRYPOINT ["/entrypoint-artifactory.sh"]