



aws cloudformation delete-stack --stack-name asg
aws cloudformation wait stack-delete-complete --stack-name asg

aws cloudformation delete-stack --stack-name alb
aws cloudformation wait stack-delete-complete --stack-name alb

aws cloudformation delete-stack --stack-name rds
aws cloudformation wait stack-delete-complete --stack-name rds

aws cloudformation delete-stack --stack-name bastion
aws cloudformation wait stack-delete-complete --stack-name bastion

aws cloudformation delete-stack --stack-name vpc
aws cloudformation wait stack-delete-complete --stack-name vpc
