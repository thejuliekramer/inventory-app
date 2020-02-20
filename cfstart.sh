#!/bin/bash

set -o errexit
set -o pipefail
# set -o nounset # This option conflicts with the use of regex matching and $BASH_REMATCH

# At this point we expect that you've already done:
#   cf set-env <appname> DS_RO_USER <datastore_username>
#   cf set-env <appname> DS_RO_PASSWORD <datastore_password>
#   cf set-env <appname> SOLR_URL <solr_url>

# CKAN wants to know about two databases. We grab those URLs from the VCAP_SERVICES env var provided by the platform
DATABASE_URL=$(echo $VCAP_SERVICES | jq -r '.["aws-rds"][] | select(.name == "inventory-db") | .credentials.uri')
DATASTORE_URL=$(echo $VCAP_SERVICES | jq -r '.["aws-rds"][] | select(.name == "inventory-datastore") | .credentials.uri')

# Parse out the elements of the datastore URL so we can make another one for the neighboring read-only user in the same DB
if [[ $DATASTORE_URL =~ (.*)'://'(.*):(.*)@(.*):([^/]*)/(.*) ]]; then
  DS_PROTOCOL=${BASH_REMATCH[1]} \
  DS_USER=${BASH_REMATCH[2]} \
  DS_PASSWORD=${BASH_REMATCH[3]} \
  DS_HOST=${BASH_REMATCH[4]} \
  DS_PORT=${BASH_REMATCH[5]} \
  DS_DBNAME=${BASH_REMATCH[6]}
else
    echo "Invalid DATASTORE_URL: " $DATASTORE_URL
    exit 1
fi


# Edit the config file to use our values
paster --plugin=ckan config-tool config/production.ini -s server:main -e port=${PORT}
paster --plugin=ckan config-tool config/production.ini \
    "sqlalchemy.url=${DATABASE_URL}" \
    "solr_url=${SOLR_URL}" \
    "ckan.datastore.write_url=${DATASTORE_URL}" \
    "ckan.datastore.read_url=${DS_PROTOCOL}://${DS_RO_USER}:${DS_RO_PASSWORD}@${DS_HOST}:${DS_PORT}/${DS_DBNAME}"

echo "Setting up the datastore user"
DS_PERMS_SQL=$(paster --plugin=ckan datastore set-permissions -c config/production.ini)
DATASTORE_URL=$DATASTORE_URL DS_RO_USER=$DS_RO_USER DS_RO_PASSWORD=$DS_RO_PASSWORD DS_PERMS_SQL=$DS_PERMS_SQL ./datastore-usersetup.py

# Run migrations
paster --plugin=ckan db upgrade -c config/production.ini

# TODO: This only applies for development; in staging and production SAML should be configured!
# In order to work around https://github.com/GSA/catalog-app/issues/78 we need PIP to make a package change
curl https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
python /tmp/get-pip.py
pip install -U repoze.who==2.0

# Fire it up!
exec paster --plugin=ckan serve config/production.ini
