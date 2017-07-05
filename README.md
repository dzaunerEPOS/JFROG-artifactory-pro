1. run `oc new-build <git checkout URL>`; this creates a new OpenShift build
2. manually start build via web interface or configure web hook to automatically trigger image build on git repository push
3. OpenShift image is now available for use in deployment config

available environment variables:
 - `DB_HOST` (default value: `postgresql`)
 - `DB_PORT` (default value: `5432`)
 - `DB_USER` (default value: `artifactory`)
 - `DB_PASSWORD` (default value: `password`)
 - `ARTIFACTORY_HOME` (default: `/var/opt/artifactory`)
 - `ARTIFACTORY_DATA` (default: `/data/artifactory`)
 - `ARTIFACTORY_USER_ID` (default: `1030`)
