#!/bin/bash

source /backup-scripts/pgenv.sh

function s3_config() {
  if [[ ! -f /root/.s3cfg ]]; then
    # If it doesn't exists, copy from ${EXTRA_CONF_DIR} directory if exists
    if [[ -f ${EXTRA_CONFIG_DIR}/s3cfg ]]; then
      cp -f ${EXTRA_CONFIG_DIR}/s3cfg /root/.s3cfg
    else
      # default value
      envsubst < /build_data/s3cfg > /root/.s3cfg
    fi
  fi

}

# Cleanup S3 bucket
function clean_s3bucket() {
  S3_BUCKET=$1
  DEL_DAYS=$2
  s3cmd ls s3://${S3_BUCKET} --recursive | while read -r line; do
    createDate=$(echo $line | awk {'print ${S3_BUCKET}" "${DEL_DAYS}'})
    createDate=$(date -d"$createDate" +%s)
    olderThan=$(date -d"-${S3_BUCKET}" +%s)
    if [[ $createDate -lt $olderThan ]]; then
      fileName=$(echo $line | awk {'print $4'})
      echo $fileName
      if [[ $fileName != "" ]]; then
        s3cmd del "$fileName"
      fi
    fi
  done
}

function dump_tables() {
  DATABASE=$1
  DATABASE_DUMP_OPTIONS=$2
  TIME_STAMP=$3
  DATA_PATH=$4
  array=($(PGPASSWORD=${POSTGRES_PASS} psql ${PG_CONN_PARAMETERS} -d ${DATABASE} -At --field-separator '.' -c "SELECT table_schema,table_name FROM information_schema.tables
where table_schema not in ('information_schema','pg_catalog','topology') and table_name
not in ('raster_columns','raster_overviews','spatial_ref_sys', 'geography_columns', 'geometry_columns')
ORDER BY table_schema,table_name;"))
  for i in "${array[@]}"; do
    #TODO split the variable i to get the schema and table names separately so that we can quote them to avoid weird table
    # names and schema names
    PGPASSWORD=${POSTGRES_PASS} pg_dump ${PG_CONN_PARAMETERS} -d ${DATABASE} ${DATABASE_DUMP_OPTIONS} -t $i >$DATA_PATH/${DATABASE}_${i}_${TIME_STAMP}.dmp
  done
}

# Env variables
MYDATE=$(date +%d-%B-%Y)
MONTH=$(date +%B)
YEAR=$(date +%Y)
MYBASEDIR=/${BUCKET}
MYBACKUPDIR=${MYBASEDIR}/${YEAR}/${MONTH}
mkdir -p ${MYBACKUPDIR}
pushd ${MYBACKUPDIR} || exit

function backup_db() {
  EXTRA_PARAMS=''
  if [ -n "$1" ]; then
    EXTRA_PARAMS=$1
  fi
  for DB in ${DBLIST}; do
    if [ -z "${ARCHIVE_FILENAME:-}" ]; then
      export FILENAME=${MYBACKUPDIR}/${DUMPPREFIX}_${DB}.${MYDATE}.dmp
    else
      export FILENAME=${MYBASEDIR}/"${ARCHIVE_FILENAME}.${DB}.dmp"
    fi
    echo "Backing up $DB" >>/var/log/cron.log
    if [ -z "${DB_TABLES:-}" ]; then
      PGPASSWORD=${POSTGRES_PASS} pg_dump ${PG_CONN_PARAMETERS} ${DUMP_ARGS} -d ${DB} > ${FILENAME}
      echo "Backing up $FILENAME done" >>/var/log/cron.log
      if [[ ${STORAGE_BACKEND} == "S3" ]]; then
        gzip $FILENAME
        echo "Backing up $FILENAME to s3://${BUCKET}/" >>/var/log/cron.log
        ${EXTRA_PARAMS}
        rm ${MYBACKUPDIR}/*.dmp.gz
      fi
    else
      dump_tables ${DB} ${DUMP_ARGS} ${MYDATE} ${MYBACKUPDIR}
      if [[ ${STORAGE_BACKEND} == "S3" ]]; then
        ${EXTRA_PARAMS}
        rm ${MYBACKUPDIR}/*
      fi
    fi
  done

}


if [[ ${STORAGE_BACKEND} == "S3" ]]; then
  s3_config
  s3cmd mb s3://${BUCKET}
  # Backup globals Always get the latest
  PGPASSWORD=${POSTGRES_PASS} pg_dumpall ${PG_CONN_PARAMETERS}  --globals-only | s3cmd put - s3://${BUCKET}/globals.sql
  echo "Sync globals.sql to ${BUCKET} bucket  " >>/var/log/cron.log
  backup_db "s3cmd sync -r ${MYBASEDIR}/* s3://${BUCKET}/"

elif [[ ${STORAGE_BACKEND} =~ [Ff][Ii][Ll][Ee] ]]; then
  # Backup globals Always get the latest
  PGPASSWORD=${POSTGRES_PASS} pg_dumpall ${PG_CONN_PARAMETERS}  --globals-only -f ${MYBASEDIR}/globals.sql
  # Loop through each pg database backing it up
  backup_db ""

fi

echo "Backup running to $MYBACKUPDIR" >>/var/log/cron.log


if [ "${REMOVE_BEFORE:-}" ]; then
  TIME_MINUTES=$((REMOVE_BEFORE * 24 * 60))
  if [[ ${STORAGE_BACKEND} == "FILE" ]]; then
    echo "Removing following backups older than ${REMOVE_BEFORE} days" >>/var/log/cron.log
    find ${MYBASEDIR}/* -type f -mmin +${TIME_MINUTES} -delete &>>/var/log/cron.log
  elif [[ ${STORAGE_BACKEND} == "S3" ]]; then
    # Credits https://shout.setfive.com/2011/12/05/deleting-files-older-than-specified-time-with-s3cmd-and-bash/
    clean_s3bucket "${BUCKET}" "${REMOVE_BEFORE} days"
  fi
fi
