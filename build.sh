#!/bin/bash
# Packer build script

set -e

# Check environment vars
if [ -z "$AWS_REGION" ]; then
    echo "Error: AWS_REGION not defined"
    exit 1
fi

if [ -z "$SECRETS_BUCKET_NAME" ]; then
    echo "Error: SECRETS_BUCKET_NAME not defined"
    exit 1
fi

# Update system packages
sudo yum update -y

# Install MySQL 5.7 (for taking backups)
sudo wget https://dev.mysql.com/get/mysql80-community-release-el7-1.noarch.rpm
sudo yum install -y https://dev.mysql.com/get/mysql80-community-release-el7-1.noarch.rpm
sudo rm -f mysql80-community-release-el7-1.noarch.rpm
sudo yum-config-manager --disable mysql-connectors-community
sudo yum-config-manager --disable mysql-tools-community
sudo yum-config-manager --disable mysql80-community
sudo yum-config-manager --enable mysql57-community
sudo yum install -y mysql-community-client

# Ensure there are no updates to be applied
sudo yum -y update

# Prepare secure backup location
sudo mkdir -p \
    ~ec2-user/mysqldump/bin \
    ~ec2-user/mysqldump/credentials \
    ~ec2-user/mysqldump/data \
    ~ec2-user/mysqldump/log

sudo chmod 700 \
    ~ec2-user/mysqldump \
    ~ec2-user/mysqldump/credentials \
    ~ec2-user/mysqldump/data

sudo chmod +x \
    ~ec2-user/s3_db_backup.sh \
    ~ec2-user/s3_db_backup_all.sh

sudo mv -f \
    ~ec2-user/s3_db_backup.sh \
    ~ec2-user/s3_db_backup_all.sh \
    ~ec2-user/mysqldump/bin/

sudo chown -R ec2-user:ec2-user ~ec2-user/mysqldump

# Sync cron configuration
aws --region "$AWS_REGION" s3 sync s3://$SECRETS_BUCKET_NAME/control/cron ./

# Configure cron tasks
sudo chown root:root ~ec2-user/*.cron
sudo mv -f ~ec2-user/*.cron /etc/cron.d/
