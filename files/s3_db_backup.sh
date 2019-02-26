#!/usr/bin/env bash
# Backup database to S3

set -e -o pipefail

SCRIPTDIR=$(dirname $0)
NOW=$(date +%Y%m%d_%H%M%S)

if [ $# -ne 8 ]; then
    echo "Usage: $0 <S3 bucket name> <S3 bucket prefix> <local DB dump dir> <SNS region> <SNS error topic> <SNS success topic> <MySQL defaults file> <MySQL database name>"
    exit 1
fi

REQUIRED_COMMANDS=(
    "gzip"
    "zcat"
    "mysqldump"
    "aws"
    "shred"
)

for REQUIRED_COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v $REQUIRED_COMMAND > /dev/null 2>&1; then
        echo "ERROR: $REQUIRED_COMMAND is not installed"
        exit 1
    fi
done

S3_BUCKET_NAME=$1
S3_BUCKET_PREFIX=$2
LOCAL_DB_DUMP_DIR=$3
SNS_REGION=$4
SNS_ERROR_TOPIC=$5
SNS_SUCCESS_TOPIC=$6
MYSQL_DEFAULTS_FILE=$7
MYSQL_DATABASE_NAME=$8

# Argument parsing
if [ -z "$S3_BUCKET_NAME" ]; then
    echo "ERROR: No S3 bucket name provided"
    exit 1
fi

if [ -z "$S3_BUCKET_PREFIX" ]; then
    echo "ERROR: No S3 bucket prefix provided"
    exit 1
fi

if [ -z "$LOCAL_DB_DUMP_DIR" ]; then
    echo "ERROR: No local DB dump dir provided"
    exit 1
fi

if [ ! -d "$LOCAL_DB_DUMP_DIR" ]; then
    echo "ERROR: Local DB dump dir does not exist or is not a directory"
    exit 1
fi

if [ -z "$SNS_REGION" ]; then
    echo "ERROR: No SNS region provided"
    exit 1
fi

if [ -z "$SNS_ERROR_TOPIC" ]; then
    echo "ERROR: No SNS error topic provided"
    exit 1
fi

if [ -z "$MYSQL_DEFAULTS_FILE" ]; then
    echo "ERROR: No MySQL defaults file provided"
    exit 1
fi

if [ -z "$MYSQL_DATABASE_NAME" ]; then
    echo "ERROR: No MySQL database name provided"
    exit 1
fi

echo "[$(date)] Starting S3 database backup"

DB_DUMP_FILENAME="mysql.${MYSQL_DATABASE_NAME}.${NOW}.sql.gz"
LOCAL_DB_DUMP_PATH="$LOCAL_DB_DUMP_DIR/$DB_DUMP_FILENAME"
S3_DB_DUMP_PATH="s3://$S3_BUCKET_NAME/$S3_BUCKET_PREFIX/$MYSQL_DATABASE_NAME/$DB_DUMP_FILENAME"

fatal_error () {
    ERROR_MESSAGE=$1

    echo "[$(date)] ERROR: $ERROR_MESSAGE"
    aws \
        --region "$SNS_REGION" \
        sns \
        publish \
        --topic-arn "$SNS_ERROR_TOPIC" \
        --subject "S3 database backup failed" \
        --message "Target S3 path: [$S3_DB_DUMP_PATH], ERROR: $ERROR_MESSAGE" \
        > /dev/null

    # Cleanup, if required
    if [ -e "$LOCAL_DB_DUMP_PATH" ]; then
        shred -fu "$LOCAL_DB_DUMP_PATH"
    fi

    exit 1
}

# Dump the database to the filesystem
echo -n "[$(date)] * Dumping database to the filesystem: "
set +e
mysqldump --defaults-file="$MYSQL_DEFAULTS_FILE" "$MYSQL_DATABASE_NAME" | gzip -c > "$LOCAL_DB_DUMP_PATH"
if [ $? -ne 0 ]; then
    echo "error."
    fatal_error "Failed dumping database to filesystem: $LOCAL_DB_DUMP_PATH"
fi
set -e
echo "done."

# Test the compressed database dump
echo -n "[$(date)] * Testing database dump: "
set +e
zcat "$LOCAL_DB_DUMP_PATH" | tail -n 1 | grep "^-- Dump completed.*" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "error."
    fatal_error "Local database file failed testing: $LOCAL_DB_DUMP_PATH"
fi
set -e
echo "done."

# Upload the database dump
echo -n "[$(date)] * Uploading database dump to S3: "
set +e
aws \
    s3 \
    cp \
    --storage-class "STANDARD_IA" \
    --only-show-errors \
    "$LOCAL_DB_DUMP_PATH" \
    "$S3_DB_DUMP_PATH"
if [ $? -ne 0 ]; then
    echo "error."
    fatal_error "Failed uploading file to S3: $LOCAL_DB_DUMP_PATH"
fi
set -e
echo "done."

# Delete the database dump
echo -n "[$(date)] * Deleting database dump from filesystem: "
set +e
shred -fu "$LOCAL_DB_DUMP_PATH"
if [ $? -ne 0 ]; then
    echo "error."
    fatal_error "Failed deleting local database file: $LOCAL_DB_DUMP_PATH"
fi
set -e
echo "done."

# Send a success notification if defined
if [ ! -z "$SNS_SUCCESS_TOPIC" ]; then
    echo -n "[$(date)] * Sending success notification: "
    aws \
        --region "$SNS_REGION" \
        sns \
        publish \
        --topic-arn "$SNS_SUCCESS_TOPIC" \
        --subject "S3 database backup success" \
        --message "$S3_DB_DUMP_PATH" \
        > /dev/null
    echo "done."
else
    echo "[$(date)] Skipping success notification"
fi

echo "[$(date)] Command complete."
