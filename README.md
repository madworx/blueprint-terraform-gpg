# Blueprint: git + Terraform + GPG (Yubikey)

_Creating reproducable and tracable infrastructure with git, Terraform, with encrypted secrets secured with Yubikey. (Persisting Terraform state into Amazon S3 + DynamoDB)_

## Table of contents

1) [Overview](#Overview)

2) [Base setup](#Base-setup)

3) [Set up required AWS infrastructure](#Set-up-required-AWS-infrastructure)

   * [Create and configure S3 bucket](#Create-and-configure-S3-bucket)
   * [Create a DynamoDB table](#Create-a-DynamoDB-table)
   * [Set up AWS account for Terraform state backend](#Set-up-AWS-account-for-Terraform-state-backend)

4) [Set up encrypted secrets files](#Set-up-encrypted-secrets-files)

5) [Set up Terraform configuration](#Set-up-Terraform-configuration)

6) [Using Terraform to provision your infrastructure](#Using-Terraform-to-provision-your-infrastructure)

7) [Addendum](#Addendum)

## Overview

This blueprint will show you how to set up your infrastructure in an
automated fashion, using Terraform with your cloud-provider secrets
encrypted via GPG/Yubikey.

This blueprint is written from the perspective of using
[Hetzner Cloud](https://www.hetzner.com/cloud), but the general
outline can be applied to any cloud provider.

The Terraform state will be persisted on Amazon S3, enabling you to
have your git repository only contain the actual configuration itself
while being able to apply changes from different workstations.

This blueprint is written to enable you to perform the required AWS
configuration, either via the AWS Web console, or the `awscli`
utility.

If you follow this blueprint, there are a few parameters you'll need
to adapt to match your environment, namely the ones mentioned in
[Base setup](#Base-setup).

The generated `setup.sh` script uses a delay of a few seconds between
operations to allow AWS to stabilize.

### Prerequisites

* Amazon AWS account with enough permissions to create resources such
  as S3 buckets, DynamoDB tables, and IAM users/policies. (If using
  the `awscli` based approach / the generated `setup.sh`, this
  credential should be configured beforehand using `aws configure`.)

* Cloud provider access for the resources you'll create. (In this
  example, we're using Hetzner Cloud, but the same principles apply
  to all cloud providers such as Amazon AWS, Microsoft Azure, etc.)

* If you wish to use the CLI based approach/the bundled script,
  you'll need a recent version of `awscli`. 
  ([Installation instructions](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html) at Amazon.)

* Working GPG setup, preferably with Yubikey or another hardware
  token.

* Working `ssh-agent` setup with an available key. (Typically
  proivded by e.g. Yubikey or other hardware token)

### Versioning guidance

This setup was written and tested using the following software
versions:

* awscli (1.16.193)
* GnuPG (2.1.18)
* jq (1.5-1-a5b5cbe)
* Terraform v0.12.1
  * provider.external v1.1.2
  * provider.hcloud v1.10.0
* Perl 5
* Yubikey 5

Some of the tools mentioned above are not critical to the setup itself, such as `jq`, `perl` and Yubikey, but if you're not using them you'll need to adapt some of the steps below.

## Base setup

If you are going to use this blueprint for copy-paste, you'll need to
start by setting up a few environment variables to start with (and
adapt them to your local environment)

``` shell
$ export GPG_IDENTITY="you@example.com"              # GPG identity
$ export AWS_S3_BUCKET="example.com-terraform-state" # S3 Bucket for state
$ export AWS_DYNAMODB_TABLE="terraform-state"        # DynamoDB locking table name
$ export AWS_IAM_USERNAME="terraform"                # AWS IAM Username
$ export AWS_REGION="eu-north-1"                     # AWS Region to use
$ export HCLOUD_TOKEN="uiyvsziuyase5jhadfalkjh45"    # Hetzner Cloud API token
$ SSH_PUBKEY="$(ssh-add -L)"
$ export SSH_PUBKEY
```

Of the above environment variables, the `${HCLOUD_TOKEN}` is the only
one that contains sensitive information; if you feel uneasy about
adding your private token to your current environment, just replace
it below in the
[Set up encrypted secrets files](#Set-up-encrypted-secrets-files) 
section below.

### Validating local environment

If any of the commands fail, start by making sure that you're using a
recent version of the `awscli` package.

After this, verify that your `awscli` has been setup with proper
credentials.

Verify that your GPG setup works by executing the following command,
which should output the string "`Works`" (assuming that you have set
the `${GPG_IDENTITY}` variable to the GPG identity you wish to use,
such as "`you@example.com`").

``` shell
$ aws sts get-caller-identity
$ echo "Works" | gpg --batch --use-agent --encrypt -r "${GPG_IDENTITY}" | \
   gpg --batch --use-agent --decrypt
```

If you receive errors about `Card error` or `Bad PIN`, this means
that something is wrong with your GPG setup.



## Set up required AWS infrastructure

Since we will be saving the Terraform state to _Amazon S3_, we will
need to create an _S3 bucket_, as well as an _DynamoDB_ table for
locking-coordination.

### Create and configure S3 bucket

#### Create bucket

We start by creating the S3 bucket in AWS in the desired region

``` shell
$ aws s3api create-bucket \
        --bucket "${AWS_S3_BUCKET}" \
        --region "${AWS_REGION}" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
        --acl private
```

#### Disable all public access to the bucket

We then proceed to disable/block all public access to the bucket and
its content (this is a relatively new feature in AWS S3, as well as
the `awscli`; If you receive errors at this stage then you need to
upgrade your `awscli` package):

``` shell
$ aws s3api put-public-access-block \
        --bucket "${AWS_S3_BUCKET}" \
        --cli-input-json '{
   "PublicAccessBlockConfiguration": {
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
   }
}'
```

#### Enable bucket versioning

By enabling versioning of bucket contents (i.e. your Terraform
state), we are protecting ourselves against accidental deletions/user
errors. (Restoring a lost Terraform state is a PITA and being able to
revert possible mistakes is gold):

``` shell
$ aws s3api put-bucket-versioning \
        --bucket "${AWS_S3_BUCKET}" \
        --versioning-configuration Status=Enabled
```

(Older versions of the state file can be restored via the AWS Console
or the `awscli` utility.)

#### Enable AWS managed encryption on bucket contents

By enabling AWS managed encryption-at-rest, we ensure that if there
should be a breach in the S3 infrastructure, the contents of our
bucket will be inaccessible without the corresponding keys owned by
AWS.

``` shell
$ aws s3api put-bucket-encryption \
        --bucket "${AWS_S3_BUCKET}" \
        --cli-input-json '{
   "ServerSideEncryptionConfiguration": {
      "Rules": [{
         "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256" } }]}}'
```

### Create a DynamoDB table

We'll need to create a DynamoDB table named `${AWS_DYNAMODB_TABLE}`,
with a `string` key named `LockID`.

``` shell
$ aws dynamodb create-table \
        --table-name "${AWS_DYNAMODB_TABLE}" \
        --cli-input-json '{
   "AttributeDefinitions": [{
      "AttributeName": "LockID",
      "AttributeType": "S"
   }],
   "KeySchema": [{
      "AttributeName": "LockID",
      "KeyType": "HASH"
   }],
   "ProvisionedThroughput": {
      "ReadCapacityUnits": 5,
      "WriteCapacityUnits": 5
   }
}'
```

### Set up AWS account for Terraform state backend

We first need to store the AWS access key for Terraform to be able to
save its state to an S3 bucket (and use DynamoDB for locking).

#### Use the IAM manager to create a named user

``` shell
$ aws iam create-user --user-name "${AWS_IAM_USERNAME}"
```

#### Create a permission policy for the Terraform user

By creating this policy (and attaching it to the user), we are
allowing the user to access the appropriate S3 bucket, as well as
using DynamoDB for lock coordination.

``` shell
$ aws iam put-user-policy --user-name "${AWS_IAM_USERNAME}" \
        --policy-name terraform-hetzner \
        --policy-document file:///dev/stdin <<EOT
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Effect": "Allow",
         "Action": "s3:ListBucket",
         "Resource": "arn:aws:s3:::${AWS_S3_BUCKET}"
      },{
         "Effect": "Allow",
         "Action": [ "s3:GetObject", "s3:PutObject" ],
         "Resource": "arn:aws:s3:::${AWS_S3_BUCKET}/hetzner.tfstate"
      },{
         "Effect": "Allow",
         "Action": [ "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem" ],
         "Resource": "arn:aws:dynamodb:*:*:table/${AWS_DYNAMODB_TABLE}"
      }
   ]
}
EOT
```

#### Create access key/secret key for user and store encrypted

``` shell
# Create API tokens ("Programmatic access") for user:
$ aws iam create-access-key --user-name "${AWS_IAM_USERNAME}" | \
# Extract the ACCESS_KEY and SECRET_KEY from JSON:
    jq -r '"access_key = \"" + .AccessKey.AccessKeyId + "\"", "secret_key = \"" + .AccessKey.SecretAccessKey + "\""' | \
# Encrypt the output using 'gpg':
    gpg --batch --use-agent --encrypt \
        -r "${GPG_IDENTITY}" > terraform-backend-variables.txt.gpg
```

The file `terraform-backend-variables.txt.gpg` now contains the AWS
access key and secret key for storing the Terraform state file into
S3 and use DynamoDB for locking.

To veirfy the contents of the file, you can use the following
command:

`$ gpg --decrypt terraform-backend-variables.json.gpg`

which should yield output akin to:

``` text
access_key = "AK................."
secret_key = "lk67dsglkj.................."
```

## Set up encrypted secrets files

Create an encrypted file, `hcloud-variables.json.gpg`, containing the
Hetzner Cloud API key and your public key:

``` shell
$ gpg --use-agent --encrypt -r "${GPG_IDENTITY}" > hcloud-variables.json.gpg <<EOT
{
   "hcloud_token": "${HCLOUD_TOKEN}",
   "ssh_pubkey":   "${SSH_PUBKEY}"
}
EOT
```

(While the SSH public key is not secret in itself, we are including
it into the encrypted file to have easy access to it later in the
process)

*Please note*: When Terraform initializes, it will write the contents
of the `terraform-backend-variables.txt.gpg` file (unencrypted) to
the file system. We'll adress this later on.

## Using Terraform to provision your infrastructure

### Creating Terraform configuration

Create the Terraform configuration, `hetzner.tf`:

(In the example below, we're using `perl` to perform expansion of the
previously set environment variables -- you can of course create this
file by yourself and fill in the details manually)

``` shell
$ perl -ne 's#%([^%]+)%#$ENV{"$1"}#e;print' > "hetzner.tf" <<'EOT'
# General configuration:
terraform {
   backend "s3" {
      region                 = "%AWS_REGION%"
      bucket                 = "%AWS_S3_BUCKET%"
      dynamodb_table         = "%AWS_DYNAMODB_TABLE%"
      key                    = "hetzner.tfstate"
      skip_region_validation = true
   }
}

data "external" "gpg" {
  program = [ "gpg", "--batch", "--use-agent", "--decrypt",
              "./hcloud-variables.json.gpg" ]
}

# Cloud provider specific configuration below:

provider "hcloud" {
  token       = "${data.external.gpg.result.hcloud_token}"
}

resource "hcloud_ssh_key" "default" {
  name        = "Yubikey stored GPG"
  public_key  = "${data.external.gpg.result.ssh_pubkey}"
}

resource "hcloud_server" "node" {
  count       = 1
  name        = "node-${count.index + 1}"
  location    = "hel1"
  image       = "debian-9"
  server_type = "cx11"
  keep_disk   = true
  ssh_keys    = [ "${hcloud_ssh_key.default.id}" ]

  provisioner "remote-exec" {
    script = "./setup-server.sh"
    connection {
      host = self.ipv4_address
      type = "ssh"
    }
  }
}
EOT
```

As you can see, we are definiting an external data provider
"external" which will decrypt the encrypted
`hcloud-variables.json.gpg` file by calling `gpg`, and provide access
to the variables inside using the `${data.external.gpg.result.KEY}`
variables.

### Create a script to perform the requested Terraform operations using the encrypted credentials

Create the `apply.sh` shell script, which will download the
`terraform` binary if it's not downloaded, and then invoke Terraform
with the (decrypted) backend secrets (AWS S3+DynamoDB)

``` shell
$ cat > "apply.sh" <<'EOT'
#!/bin/bash

TERRAFORM_VERSION="0.12.1"

ACTION=(${@:-apply})

set -eE
set -o pipefail
set -x

if [ ! -x ./terraform ] ; then
    echo "Downloading Terraform..."
    wget -O terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    unzip terraform.zip terraform
    rm -f terraform.zip 2>/dev/null
fi

LOCAL_STATE=".terraform/terraform.tfstate"
rm -f "${LOCAL_STATE}" || true
./terraform init -backend-config=<(gpg --batch --decrypt terraform-backend-variables.txt.gpg 2>/dev/null)
time ./terraform "${ACTION[@]}"
rm -f "${LOCAL_STATE}" || true
EOT
$ 
$ chmod +x apply.sh
```

You'll also want to add the `terraform` binary to the `.gitignore` file:
``` shell
$ egrep -q '^terraform$' .gitignore || echo 'terraform' >> .gitignore
$ egrep -q '^[.]terraform$' .gitignore || echo '.terraform' >> .gitignore
$ git add .gitignore
$ git commit -m 'Added terraform binary and .terraform directory to .gitignore' .gitignore
```

You can now run the  `apply.sh` command to create the infrastructure you've configured:

`./apply.sh`

