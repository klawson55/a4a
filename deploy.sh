#!/bin/bash
set +x
#set -x
#trap read debug

APPNAME=a4a
DOMAINNAME=klawson.info
REGION=us-west-2
ENVIRONMENT=$1
DBPASSWORD=$2
AMI_ID=ami-223f945a  #Red Hat Enterprise Linux 7.4 (HVM), SSD

# create DNS zone if it doesn't exist
myZones=$(
  aws route53 list-hosted-zones --query 'HostedZones[*].{ID:Id,Name:Name}' --output=text
)
if [ -z "$myZones" ] || ! [[ $myZones =~ .*$DOMAINNAME*. ]]; then
  aws route53 create-hosted-zone --name $DOMAINNAME --caller-reference "createZone-`date -u +"%Y-%m-%dT%H:%M:%SZ"`"
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

# create a bastion if it doesn't exist
BASTION=$(
  aws ec2 describe-instances 
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
	ParameterKey=InstanceType,ParameterValue=t2.small \
	ParameterKey=SubDomainName,ParameterValue=ssh-bastion \
	ParameterKey=PublicHostedZoneName,ParameterValue=klawson.info.

  aws cloudformation wait stack-create-complete --stack-name bastion
else
  echo "Found database"
fi

# create an application keypair if it doesn't exist
KEY_EXISTS=$(aws ec2 describe-key-pairs --key-names kp-$APPNAME --output text)
if [ -z "$KEY_EXISTS" ]; then
  aws ec2 create-key-pair --key-name kp-$APPNAME --query 'KeyMaterial' --output text > ~/.ssh/kp-$APPNAME.pem
  chmod 0400 ~/.ssh/kp-$APPNAME.pem
else
  echo "Found application key pair"
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

set -x
trap read debug

# create launch config if it doesn't exist
db=$(
  aws cloudformation describe-stacks --stack-name asg
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
  echo "Found launch configuration"
fi
