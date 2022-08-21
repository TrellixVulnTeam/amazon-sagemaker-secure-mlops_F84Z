#!/bin/bash

# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

# This script will package the CloudFormation in ${CFN_TEMPLATE_DIR} directory and upload it 
# to Amazon S3 in preparation for deployment using the AWS CloudFromation service.  
# 
# This script exists because Service Catalog products, when using relative references to cloudformation templates are 
# not properly packaged by the AWS cli. Also the full stack, due to 2 levels of Service Catalog deployment will not 
# always package properly using the AWS cli.

# This script treats the templates as source code and packages them, putting the results into a 'build' subdirectory.

# This script assumes a Linux or MacOSX environment and relies on the following software packages being installed:
# . - AWS Command Line Interface (CLI)
# . - sed
# . - Python 3 / pip3
# . - zip

# PLEASE NOTE this script will store all resources to an Amazon S3 bucket s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}
CFN_BUCKET_NAME=$1
DEPLOYMENT_REGION=$2
PROJECT_NAME="sagemaker-mlops"
CFN_TEMPLATE_DIR="cfn_templates"
SEED_CODE_DIR="mlops-seed-code"
CFN_OUTPUT_DIR="build/${DEPLOYMENT_REGION}"
SEED_CODE_OUTPUT_DIR="build/${DEPLOYMENT_REGION}/seed-code"

# files that need to be scrubbed with sed to replace < S3 BUCKET LOCATION > with an actual S3 bucket name
SELF_PACKAGE_LIST="core-sc-shared-portfolio.yaml env-sc-portfolio.yaml env-main.yaml"

# files to be packaged using `aws cloudformation package`
AWS_PACKAGE_LIST="core-main.yaml env-main.yaml data-science-environment-quickstart.yaml"

# files that wont be uploaded by `aws cloudformation package`
UPLOAD_LIST="core-main.yaml env-main.yaml data-science-environment-quickstart.yaml env-sc-portfolio.yaml env-iam-target-account-roles.yaml env-vpc.yaml project-model-deploy.yaml project-model-build-train.yaml" 

# Check that S3 bucket exists, if not create a new one
if aws s3 ls s3://${CFN_BUCKET_NAME} 2>&1 | grep NoSuchBucket
then
    echo Creating Amazon S3 bucket ${CFN_BUCKET_NAME}
    aws s3 mb s3://${CFN_BUCKET_NAME} --region $DEPLOYMENT_REGION
fi
echo "\e[1;33mPreparing content for publication to Amazon S3 s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}"

## clean away any previous builds of the CFN
rm -fr ${CFN_OUTPUT_DIR}
rm -fr ${SEED_CODE_OUTPUT_DIR}
mkdir -p ${CFN_OUTPUT_DIR}
mkdir -p ${SEED_CODE_OUTPUT_DIR}
rm -f build/*-${DEPLOYMENT_REGION}.zip
cp ${CFN_TEMPLATE_DIR}/*.yaml ${CFN_OUTPUT_DIR}

# Zip the source code
echo "\e[1;33mZipping the source code"
rm -f sagemaker-secure-mlops.zip
zip -r sagemaker-secure-mlops.zip . -x "*.pdf" -x "*.git*" -x "*.DS_Store*" -x "*.vscode*" -x "/build/*" -x "internal-documents*"

## Zip the templates
echo "\e[1;33mZipping CloudFormation templates in ${CFN_OUTPUT_DIR}"
zip -r build/cfn-templates-${DEPLOYMENT_REGION}.zip ${CFN_OUTPUT_DIR}/*.yaml

## Zip the MLOps project seed code for
echo "\e[1;33mZipping MLOps project seed code"
(cd ${SEED_CODE_DIR}/model-deploy/ && zip -r ../../${SEED_CODE_OUTPUT_DIR}/mlops-model-deploy-v1.0.zip .)
(cd ${SEED_CODE_DIR}/model-build-train/ && zip -r ../../${SEED_CODE_OUTPUT_DIR}/mlops-model-build-train-v1.0.zip .)

## publish materials to target AWS regions
echo "\e[1;33mPublishing CloudFormation to ${DEPLOYMENT_REGION}"
echo "\e[1;33mClearing the project directory for ${PROJECT_NAME} in ${CFN_BUCKET_NAME}..."

aws s3 rm \
    s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}/ \
    --recursive \
    --region ${DEPLOYMENT_REGION}

echo "\e[1;33mSelf-packaging the Cloudformation templates: ${SELF_PACKAGE_LIST}"
for fname in ${SELF_PACKAGE_LIST};
do
    sed -ie "s/< S3_CFN_STAGING_PATH >/${PROJECT_NAME}/" ${CFN_OUTPUT_DIR}/${fname}
    sed -ie "s/< S3_CFN_STAGING_BUCKET >/${CFN_BUCKET_NAME}/" ${CFN_OUTPUT_DIR}/${fname}
    sed -ie "s/< S3_CFN_STAGING_BUCKET_PATH >/${CFN_BUCKET_NAME}\/${PROJECT_NAME}/" ${CFN_OUTPUT_DIR}/${fname}
done

echo "\e[1;33mPackaging Cloudformation templates: ${AWS_PACKAGE_LIST}"
for fname in ${AWS_PACKAGE_LIST};
do
    pushd ${CFN_OUTPUT_DIR}
    aws cloudformation package \
        --template-file ${fname} \
        --s3-bucket ${CFN_BUCKET_NAME} \
        --s3-prefix ${PROJECT_NAME} \
        --output-template-file ${fname}-packaged \
        --region ${DEPLOYMENT_REGION}
    popd
done

# copy source code .zip file to the S3 bucket
aws s3 cp sagemaker-secure-mlops.zip s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}/

# copy all seed-code .zip files from ${SEED_CODE_OUTPUT_DIR} to S3
aws s3 cp ${SEED_CODE_OUTPUT_DIR} s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}/seed-code/ --recursive

# put an object tag servicecatalog:provisioning=true for AmazonSageMakerServiceCatalogProductsLaunchRole access
for fname in ${SEED_CODE_OUTPUT_DIR}/*
do
    echo "\e[1;33mSet servicecatalog:provisioning=true tag to object: ${fname}"
    aws s3api put-object-tagging \
        --bucket ${CFN_BUCKET_NAME} \
        --key ${PROJECT_NAME}/seed-code/$(basename $fname) \
        --tagging 'TagSet=[{Key=servicecatalog:provisioning,Value=true}]'
done

# push files to S3, note this does not 'package' the templates
echo "\e[1;33mCopying cloudformation templates and files to S3: ${UPLOAD_LIST}"
for fname in ${UPLOAD_LIST};
do
    if [ -f ${CFN_OUTPUT_DIR}/${fname}-packaged ]; then
        aws s3 cp ${CFN_OUTPUT_DIR}/${fname}-packaged s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}/${fname}
    else
        aws s3 cp ${CFN_OUTPUT_DIR}/${fname} s3://${CFN_BUCKET_NAME}/${PROJECT_NAME}/${fname}
    fi

    echo "To validate template ${fname}:"
    echo "aws cloudformation validate-template --template-url https://s3.${DEPLOYMENT_REGION}.amazonaws.com/${CFN_BUCKET_NAME}/${PROJECT_NAME}/${fname}"

    echo "To deploy stack execute:"
    echo "aws cloudformation create-stack --template-url https://s3.${DEPLOYMENT_REGION}.amazonaws.com/${CFN_BUCKET_NAME}/${PROJECT_NAME}/${fname} --region ${DEPLOYMENT_REGION} --stack-name <STACK_NAME> --disable-rollback --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --parameters ParameterKey=,ParameterValue=" 

done

echo ==================================================
echo "\e[1;32mPublication complete"
