#!/bin/bash
set +x

# Registered klawson.info with goDaddy and delegated DNS to Route 53
# Requested a public certificate, validated with DNS CNAME record

APPNAME=a4a
DOMAIN_NAME=klawson.info
REGION=us-west-2
ENVIRONMENT=$1
DBPASSWORD=$2
AMI_ID=ami-223f945a  #Red Hat Enterprise Linux 7.4 (HVM), SSD
INSTANCETYPE=t2.small

# create DNS zone if it doesn't exist
# the query is returning /hostedzone/Z2KUT1VP1GH4IB; need just the zone ID
ZONE_ID=$(
  aws route53 list-hosted-zones --query 'HostedZones[*].Id' --output text | awk -F'/' '{print $3}'
)
if [ -z "$ZONE_ID" ] || ! [[ $ZONE_ID =~ .*$DOMAIN_NAME*. ]]; then
  aws route53 create-hosted-zone --name $DOMAIN_NAME --caller-reference "createZone-`date -u +"%Y-%m-%dT%H:%M:%SZ"`"
  sleep 10
else
  echo "Found DNS zone"
fi

# get certificate arn
CERT_ARN=$(
  aws acm list-certificates --query 'CertificateSummaryList[*].CertificateArn' --output text
)

# create VPC if it doesn't exist
VPC_ID=$(
  aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text
)
if  [ -z "$VPC_ID" ] || [ "${VPC_ID}" == "None" ]; then
  aws cloudformation create-stack --region=$REGION --stack-name vpc --template-body file://vpc.yml

  aws cloudformation wait stack-create-complete --stack-name vpc

  VPC_ID=$(
    aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text
  )
else
  echo "Found VPC"
fi

# create a bastion keypair if it doesn't exist
KEY_EXISTS=$(aws ec2 describe-key-pairs --key-names kp-bastion --output text)
if [ -z "$KEY_EXISTS" ]; then
  aws ec2 create-key-pair --key-name kp-bastion --query 'KeyMaterial' --output text > ~/.ssh/kp-bastion.pem
  chmod 0400 ~/.ssh/kp-bastion.pem
else
  echo "Found bastion key pair"
fi

set -x
trap read debug

# create a bastion if it doesn't exist
BASTION=$(
  aws cloudformation describe-stacks --stack-name bastion --query 'Stacks[*].StackId' --output text
)
if  [ -z "$BASTION" ] || [ "${BASTION}" == "None" ]; then
	aws cloudformation create-stack \
		--region=$REGION \
		--stack-name bastion \
		--template-body file://bastion.yml \
		--parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
		ParameterKey=VpcId,ParameterValue=$VPC_ID \
		ParameterKey=AmiId,ParameterValue=$AMI_ID \
		ParameterKey=KeyName,ParameterValue=kp-bastion \
		ParameterKey=InstanceType,ParameterValue=$INSTANCETYPE \
		ParameterKey=SubDomainName,ParameterValue=ssh \
		ParameterKey=PublicHostedZoneName,ParameterValue=klawson.info.

  aws cloudformation wait stack-create-complete --stack-name bastion
else
  echo "Found database"
fi

# create database if it doesn't exist
db=$(
  aws rds describe-db-instances
)
if  [ -z "$db" ] || [ "${db}" == "None" ] || [ ${#db} -lt 50 ]; then
	aws cloudformation create-stack \
		--region=$REGION \
		--stack-name rds \
		--template-body file://rds.yml \
		--parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
		ParameterKey=DatabaseInstanceClass,ParameterValue=db.t2.small \
		ParameterKey=DatabaseEngine,ParameterValue=aurora \
		ParameterKey=DatabaseUser,ParameterValue=dbadmin \
		ParameterKey=DatabasePassword,ParameterValue=$DBPASSWORD \
		ParameterKey=DatabaseName,ParameterValue=nonProdA4A

  aws cloudformation wait stack-create-complete --stack-name rds
else
  echo "Found database"
fi

# identify the database in read/write mode (the other is in read-only)
DB_WRITER=$(
  aws rds describe-db-clusters --query 'DBClusters[*].DBClusterMembers[0].DBInstanceIdentifier' --output text
)
DB_WRITER_ARN=$(
  aws rds describe-db-instances --db-instance-identifier rdf7cqpw6n9uv --query 'DBInstances[*].DBInstanceArn' --output text
)

# create ALB if it doesn't exist
ALB=$(
  aws cloudformation describe-stacks --stack-name asg --query 'Stacks[*].StackId' --output text
)
if  [ -z "$ALB" ] || [ "${ALB}" == "None" ] || [ ${#ALB} -lt 50 ]; then
	aws cloudformation create-stack \
		--region=$REGION \
		--stack-name alb \
		--template-body file://alb.yml \
		--parameters ParameterKey=EnvironmentName,ParameterValue=$ENVIRONMENT \
		ParameterKey=LoadBalancerScheme,ParameterValue='internet-facing' \
		ParameterKey=LoadBalancerCertificateArn,ParameterValue=$CERT_ARN \
		ParameterKey=LoadBalancerDeregistrationDelay,ParameterValue=300 \
		ParameterKey=PublicHostedZoneName,ParameterValue=$DOMAIN_NAME \
		ParameterKey=PublicHostedZoneId,ParameterValue=$ZONE_ID \
		ParameterKey=VpcId,ParameterValue=$VPC_ID
	
  aws cloudformation wait stack-create-complete --stack-name rds
else
  echo "Found ALB"
fi

# create an application keypair if it doesn't exist
APP_KEY=$(aws ec2 describe-key-pairs --key-names kp-$APPNAME --output text)
if [ -z "$APP_KEY" ]; then
  aws ec2 create-key-pair --key-name kp-$APPNAME --query 'KeyMaterial' --output text > ~/.ssh/kp-$APPNAME.pem
  chmod 0400 ~/.ssh/kp-$APPNAME.pem
else
  echo "Found application key pair"
fi

# create auto-scaling group if it doesn't exist
ASG=$(
  aws cloudformation describe-stacks --stack-name asg --query 'Stacks[*].StackId' --output text
)
if  [ -z "$ASG" ] || [ "${ASG}" == "None" ] || [ ${#ASG} -lt 50 ]; then
  TARGET_GROUP_ARN=$(
	  aws elbv2 describe-target-groups --query 'TargetGroups[*].TargetGroupArn' --output text
	)
	aws cloudformation create-stack \
		--region=$REGION \
		--stack-name asg \
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
		ParameterKey=TargetGroupARNs,ParameterValue=$TARGET_GROUP_ARN \
		ParameterKey=VpcId,ParameterValue=$VPC_ID
	
  aws cloudformation wait stack-create-complete --stack-name rds
else
  echo "Found launch configuration"
fi
