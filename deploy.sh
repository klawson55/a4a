#!/bin/bash
set -x
trap read debug

APPNAME=a4a
DOMAINNAME=klawson.info
REGION=us-west-2
ENVIRONMENT=$2
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

# create an a application keypair if it doesn't exist
KEY_EXISTS=$(aws ec2 describe-key-pairs --key-names kp-$APPNAME --output text)
if [ -z "$KEY_EXISTS" ]; then
  aws ec2 create-key-pair --key-name kp-$APPNAME --query 'KeyMaterial' --output text > ~/.ssh/kp-$APPNAME.pem
  chmod 0400 ~/.ssh/kp-$APP.pem
fi

