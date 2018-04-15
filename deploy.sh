#!/bin/bash
# Registered klawson.info with goDaddy and delegated DNS to Route 53
# Requested a public certificate, validated with DNS CNAME record
set +x

#set -x
#trap read debug
# add logic to compress and upload amazonaws.com/a4a-klawson/a4a-cookbook.tgz
# referenced in the launch LaunchConfiguration

if [ "$#" -lt 2 ]; then
  echo "Usage: bash deploy.sh ENVIRONMENT DB_PASSWORD REGION"
  exit 1
fi

DEPLOY_DATETIME=$(date +%Y%m%d:%H%M)
APPNAME=a4a
DOMAIN_NAME=klawson.info
if [ -z "$3" ]; then
  REGION=us-west-2
else
  REGION=$3
fi
ENVIRONMENT=$1
DBPASSWORD=$2
AMI_ID=ami-223f945a  #Red Hat Enterprise Linux 7.4 (HVM), SSD
INSTANCETYPE=t2.small

# create DNS zone if it doesn't exist
# the query is returning /hostedzone/Z2KUT1VP1GH4IB; need just the zone ID
ZONE_ID=$(
  aws route53 list-hosted-zones --query 'HostedZones[*].Id' --output text | awk -F'/' '{print $3}'
)
if [ -z "$ZONE_ID" ]; then
  aws route53 create-hosted-zone --name $DOMAIN_NAME --caller-reference "createZone-`date -u +"%Y-%m-%dT%H:%M:%SZ"`"
  sleep 10
else
  echo "Found DNS zone"
fi

# get certificate arn
CERT_ARN=$(
  aws acm list-certificates --query 'CertificateSummaryList[*].CertificateArn' --output text
)

# create VPC if it doesn't exist.  Will update if anything changed
STACK_NAME=vpc
VPC_ID=$(
  aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text
)

if  [ -z "$VPC_ID" ] || [ "${VPC_ID}" == "None" ]; then
  STACK_ACTION="create"
  echo "creating ${STACK_NAME}"
else
  STACK_ACTION="update"
  echo "updating ${STACK_NAME}"
fi

STATUS=$(
  aws cloudformation "${STACK_ACTION}-stack" \
    --region=$REGION --stack-name $STACK_NAME --template-body file://vpc.yml
)

# process hangs if we call for a "wait" on a stack that doesn't have an update
if [ -z "$STATUS" ] || [[ $STATUS = *"No updates are to be performed"* ]]; then
  echo "No update to existing ${STACK_NAME} stack"
else
  aws cloudformation wait "stack-${STACK_ACTION}-complete" --stack-name $STACK_NAME
fi

if [ "${STACK_ACTION}" == "create" ]; then
  VPC_ID=$(
    aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text
  )
fi

# create a bastion if it doesn't exist.  Will update if anything changed
BASTION_HOSTNAME=ssh
STACK_NAME=bastion
# create a bastion keypair if it doesn't exist
KEY_EXISTS=$(
  aws ec2 describe-key-pairs --key-names kp-$STACK_NAME --output text
)
if [ -z "$KEY_EXISTS" ]; then
  if [ -f ~/.ssh/kp-$STACK_NAME.pem ]; then
    mv ~/.ssh/kp-$STACK_NAME.pem ~/.ssh/kp-$STACK_NAME.pem-$DEPLOY_DATETIME
  fi
  aws ec2 create-key-pair --region=$REGION --key-name kp-$STACK_NAME --query 'KeyMaterial' --output text > ~/.ssh/kp-$STACK_NAME.pem
  chmod 0400 ~/.ssh/kp-$STACK_NAME.pem
else
  echo "Found bastion key pair"
fi

BASTION=$(
  aws cloudformation describe-stacks --region=$REGION --stack-name $STACK_NAME --query 'Stacks[*].StackId' --output text
)

if  [ -z "$BASTION" ] || [ "${BASTION}" == "None" ]; then
  STACK_ACTION="create"
  echo "creating ${STACK_NAME}"
else
  STACK_ACTION="update"
  echo "updating ${STACK_NAME}"
fi

STATUS=$(
  aws cloudformation "${STACK_ACTION}-stack" \
    --region=$REGION \
    --stack-name $STACK_NAME \
    --template-body file://bastion.yml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=AmiId,ParameterValue=$AMI_ID \
    ParameterKey=KeyName,ParameterValue=kp-$STACK_NAME \
    ParameterKey=InstanceType,ParameterValue=$INSTANCETYPE \
    ParameterKey=SubDomainName,ParameterValue=$BASTION_HOSTNAME \
    ParameterKey=PublicHostedZoneName,ParameterValue=$DOMAIN_NAME.
)

# process hangs if we call for a "wait" on a stack that doesn't have an update
if [ -z "$STATUS" ] || [[ $STATUS = *"No updates are to be performed"* ]]; then
  echo "No update to existing ${STACK_NAME} stack"
else
  aws cloudformation wait "stack-${STACK_ACTION}-complete" --stack-name $STACK_NAME
fi

# create database if it doesn't exist.  Will update if anything changed
STACK_NAME=rds
DB=$(
  aws rds describe-db-instances --region=$REGION
)

if  [ -z "$DB" ] || [ "${DB}" == "None" ] || [ ${#DB} -lt 50 ]; then
  STACK_ACTION="create"
  echo "creating ${STACK_NAME}"
else
  STACK_ACTION="update"
  echo "updating ${STACK_NAME}"
fi

STATUS=$(
  aws cloudformation "${STACK_ACTION}-stack" \
    --region=$REGION \
    --stack-name $STACK_NAME \
    --template-body file://rds.yml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
    ParameterKey=DatabaseInstanceClass,ParameterValue=db.t2.small \
    ParameterKey=DatabaseEngine,ParameterValue=aurora \
    ParameterKey=DatabaseUser,ParameterValue=dbadmin \
    ParameterKey=DatabasePassword,ParameterValue=$DBPASSWORD \
    ParameterKey=DatabaseName,ParameterValue=$APPNAME
)

# process hangs if we call for a "wait" on a stack that doesn't have an update
if [ -z "$STATUS" ] || [[ $STATUS = *"No updates are to be performed"* ]]; then
  echo "No update to existing ${STACK_NAME} stack"
else
  aws cloudformation wait "stack-${STACK_ACTION}-complete" --stack-name $STACK_NAME
fi

# identify the database in read/write mode (the other is in read-only)
# should add logic to ensure the database was created successfully and that
# we're able to get db_writer, and db_writer_arn successfully
DB_WRITER=$(
  aws rds describe-db-clusters --region=$REGION --query 'DBClusters[*].DBClusterMembers[0].DBInstanceIdentifier' --output text
)
DB_WRITER_ARN=$(
  aws rds describe-db-instances --region=$REGION --db-instance-identifier $DB_WRITER --query 'DBInstances[*].DBInstanceArn' --output text
)

# create ALB if it doesn't exist.  Will update if anything changed
STACK_NAME=alb
ALB=$(
  aws cloudformation describe-stacks --region=$REGION --stack-name alb --query 'Stacks[*].StackId' --output text
)
if  [ -z "$ALB" ] || [ "${ALB}" == "None" ] || [ ${#ALB} -lt 50 ]; then
  STACK_ACTION="create"
  echo "creating ${STACK_NAME}"
else
  STACK_ACTION="update"
  echo "updating ${STACK_NAME}"
fi

STATUS=$(
  aws cloudformation "${STACK_ACTION}-stack" \
    --region=$REGION \
    --stack-name $STACK_NAME \
    --template-body file://alb.yml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
    ParameterKey=ApplicationName,ParameterValue=$APPNAME \
    ParameterKey=LoadBalancerScheme,ParameterValue='internet-facing' \
    ParameterKey=LoadBalancerCertificateArn,ParameterValue=$CERT_ARN \
    ParameterKey=LoadBalancerDeregistrationDelay,ParameterValue=300 \
    ParameterKey=PublicHostedZoneName,ParameterValue=$DOMAIN_NAME. \
    ParameterKey=PublicHostedZoneId,ParameterValue=$ZONE_ID \
    ParameterKey=VpcId,ParameterValue=$VPC_ID
)

# process hangs if we call for a "wait" on a stack that doesn't have an update
if [ -z "$STATUS" ] || [[ $STATUS = *"No updates are to be performed"* ]]; then
  echo "No update to existing ${STACK_NAME} stack"
else
  aws cloudformation wait "stack-${STACK_ACTION}-complete" --stack-name $STACK_NAME
fi

# create an application keypair if it doesn't exist.  Will update if anything changed
STACK_NAME=$APPNAME
APP_KEY=$(
  aws ec2 describe-key-pairs --key-names kp-$STACK_NAME --output text
)
if [ -z "$APP_KEY" ]; then
  if [ -f ~/.ssh/kp-$STACK_NAME.pem ]; then
    mv ~/.ssh/kp-$STACK_NAME.pem ~/.ssh/kp-$STACK_NAME.pem-$DEPLOY_DATETIME
  fi
  aws ec2 create-key-pair --region=$REGION --key-name kp-$STACK_NAME --query 'KeyMaterial' --output text > ~/.ssh/kp-$STACK_NAME.pem
  chmod 0400 ~/.ssh/kp-$STACK_NAME.pem
else
  echo "Found application key pair"
fi

# create auto-scaling group if it doesn't exist.  Will update if anything changed
STACK_NAME=asg
ASG=$(
  aws cloudformation describe-stacks --region=$REGION --stack-name asg --query 'Stacks[*].StackId' --output text
)
TARGET_GROUP_ARN=$(
  aws elbv2 describe-target-groups --region=$REGION --query 'TargetGroups[*].TargetGroupArn' --output text
)
if  [ -z "$ASG" ] || [ "${ASG}" == "None" ] || [ ${#ASG} -lt 50 ]; then
  STACK_ACTION="create"
  echo "creating ${STACK_NAME}"
else
  STACK_ACTION="update"
  echo "updating ${STACK_NAME}"
fi

STATUS=$(
  aws cloudformation "${STACK_ACTION}-stack" \
    --region=$REGION \
    --stack-name $STACK_NAME \
    --template-body file://asg.yml \
    --parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
    ParameterKey=ApplicationName,ParameterValue=$APPNAME \
    ParameterKey=Role,ParameterValue=web \
    ParameterKey=AmiId,ParameterValue=$AMI_ID \
    ParameterKey=MaximumInstances,ParameterValue=2 \
    ParameterKey=MinimumInstances,ParameterValue=1 \
    ParameterKey=MinimumViableInstances,ParameterValue=1 \
    ParameterKey=InstanceType,ParameterValue=$INSTANCETYPE \
    ParameterKey=KeyName,ParameterValue=kp-$APPNAME \
    ParameterKey=TGARNs,ParameterValue=$TARGET_GROUP_ARN \
    ParameterKey=VpcId,ParameterValue=$VPC_ID
)

# process hangs if we call for a "wait" on a stack that doesn't have an update
if [ -z "$STATUS" ] || [[ $STATUS = *"No updates are to be performed"* ]]; then
  echo "No update to existing ${STACK_NAME} stack"
else
  aws cloudformation wait "stack-${STACK_ACTION}-complete" --stack-name $STACK_NAME
fi
