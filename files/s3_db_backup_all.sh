#!/usr/bin/env bash
# Wrapper script to synchronise the credential files and dump all databases to S3

SCRIPTDIR=$(dirname $0)

echo "[$(date)] S3 DB backup all process started..."

if [ $# -ne 6 ]; then
    echo "Usage: $0 <secrets bucket name> <backup bucket name> <mysqldump root backup location> <S3 backup bucket region> <SNS error topic ARN> <SNS region>"
    exit 1
fi

# Arguments
SECRETS_BUCKET_NAME=$1
BACKUP_BUCKET_NAME=$2
BACKUP_ROOT_PATH=$3
S3_REGION=$4
SNS_ERROR_TOPIC=$5
SNS_REGION=$6

# Calculated variables
BACKUP_DATA_PATH="$BACKUP_ROOT_PATH/data"
BACKUP_CREDENTIALS_PATH="$BACKUP_ROOT_PATH/credentials"

fatal_error () {
    ERROR_MESSAGE=$1

    echo "[$(date)] ERROR: $ERROR_MESSAGE"
    aws \
        --region "$SNS_REGION" \
        sns \
        publish \
        --topic-arn "$SNS_ERROR_TOPIC" \
        --subject "S3 database backup all script failed" \
        --message "ERROR: $ERROR_MESSAGE" \
        > /dev/null

    exit 1
}

error () {
    ERROR_MESSAGE=$1

    echo "[$(date)] ERROR: $ERROR_MESSAGE"
    aws \
        --region "$SNS_REGION" \
        sns \
        publish \
        --topic-arn "$SNS_ERROR_TOPIC" \
        --subject "S3 database backup all script error" \
        --message "ERROR: $ERROR_MESSAGE" \
        > /dev/null

    exit 1
}

# Argument checks
if [ -z "$SECRETS_BUCKET_NAME" ]; then
    fatal_error "No secrets bucket name provided"
fi

if [ -z "$BACKUP_BUCKET_NAME" ]; then
    fatal_error "No backup bucket name provided"
fi

if [ -z "$BACKUP_ROOT_PATH" ]; then
    fatal_error "No backup root path provided"
fi

if [ ! -d "$BACKUP_ROOT_PATH" ]; then
    fatal_error "Backup root path does not exist or is not a directory"
fi

if [ ! -d "$BACKUP_DATA_PATH" ]; then
    fatal_error "Backup data path does not exist or is not a directory [$BACKUP_DATA_PATH]"
fi

if [ ! -d "$BACKUP_CREDENTIALS_PATH" ]; then
    fatal_error "Backup credentials path does not exist or is not a directory [$BACKUP_CREDENTIALS_PATH]"
fi

if [ -z "$S3_REGION" ]; then
    fatal_error "No S3 region provided"
fi

if [ -z "$SNS_ERROR_TOPIC" ]; then
    fatal_error "No SNS error topic ARN provided"
fi

if [ -z "$SNS_REGION" ]; then
    fatal_error "No SNS error ARN region provided"
fi

# Synchronise the credential files
# NOTE: this will delete any credential files on the server that are not in S3
# (this means you can self-manage backups entirely from S3 without needing to
# go manually delete files from the control server if you drop an unneeded DB)
echo "[$(date)] Synchronising credential files..."

aws \
    --region "$S3_REGION" \
    s3 \
    sync \
    --delete \
    "s3://$SECRETS_BUCKET_NAME/control/mysqldump" \
    "$BACKUP_CREDENTIALS_PATH"

if [ $? -ne 0 ]; then
    error "Failed copying secrets to instance"
fi

echo "[$(date)] Done."

# Dump each database (credential file) in turn
for CNF_FILE in $(ls $BACKUP_CREDENTIALS_PATH/|grep -i '\.cnf$'); do
    echo "[$(date)] Processing [$CNF_FILE]..."

    DATABASE_NAME=$(echo "$CNF_FILE" | sed -e 's/\.cnf$//')

    if [ -z "$DATABASE_NAME" ]; then
        error "No database name for [$CNF_FILE], skipping..."
        continue
    fi

    echo "[$(date)] Backing up [$DATABASE_NAME]..."

    $SCRIPTDIR/s3_db_backup.sh \
        "$BACKUP_BUCKET_NAME" \
        "database" \
        "$BACKUP_DATA_PATH" \
        "$SNS_REGION" \
        "$SNS_ERROR_TOPIC" \
        "" \
        "$BACKUP_CREDENTIALS_PATH/$CNF_FILE" \
        "$DATABASE_NAME"

    if [ $? -ne 0 ]; then
        error "Failed dumping database [$CNF_FILE]"
    fi

    echo "[$(date)] Done."
done

echo "[$(date)] Command complete."
