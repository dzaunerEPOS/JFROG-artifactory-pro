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

# Artifactory homes
RUN mkdir -pv /data/artifactory
#RUN chmod 777 -R /data/artifactory
RUN chown -R 1030:1030 /data

# Disable Tomcat's manager application.
RUN rm -rf webapps/*

# Grab PostgreSQL driver
RUN curl -L# -o /usr/local/tomcat/lib/postgresql-${POSTGRESQL_JAR_VERSION}.jar ${POSTGRESQL_JAR}

# Expose tomcat runtime options through the RUNTIME_OPTS environment variable.
#   Example to set the JVM's max heap size to 256MB use the flag
#   '-e RUNTIME_OPTS="-Xmx256m"' when starting a container.
RUN echo 'export CATALINA_OPTS="$RUNTIME_OPTS"' > bin/setenv.sh

# Running under non-root user to allow non-privileged container execution
#USER 1030

# Fetch and install Artifactory OSS war archive.
RUN \
  curl -L# -o /tmp/artifactory.zip ${ARTIFACTORY_URL} && \
  unzip /tmp/artifactory.zip -d /tmp && \
  mkdir -p /var/opt/artifactory && \
  mv /tmp/artifactory-pro-${ARTIFACTORY_VERSION}/* /var/opt/artifactory && \
  rm -r /tmp/artifactory.zip /tmp/artifactory-pro-${ARTIFACTORY_VERSION}

# Deploy Entry Point
RUN apt-get update && apt-get install -y gosu
COPY files/entrypoint-artifactory.sh / 
# Adjust directory for sanity checks
RUN sed -i 's/\$ARTIFACTORY_HOME\/tomcat/\/usr\/local\/tomcat/g' /entrypoint-artifactory.sh

# Change default port to 8080
RUN sed -i 's/port="8081"/port="8080"/' ${ARTIFACTORY_HOME}/tomcat/conf/server.xml

# Expose Artifactories data directory
VOLUME /data/artifactory

WORKDIR /data/artifactory

ENTRYPOINT ["/bin/bash"]
CMD ["/entrypoint-artifactory.sh"]