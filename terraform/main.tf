terraform {
  required_version = ">= 1.2.0"

  backend "s3" {
    bucket = "jmkriz"
    key    = "terraform/backend"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# DynamoDB table for visitor count
resource "aws_dynamodb_table" "resume_visitor_count" {
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  name         = "resume"

  attribute {
    name = "id"
    type = "S"
  }
}

# Lambda function to access and increment visitor count
resource "aws_signer_signing_profile" "visitor_counter_sp" {
  platform_id = "AWSLambda-SHA384-ECDSA"
  name_prefix = "visitor_counter_sp_"

  signature_validity_period {
    value = 5
    type  = "YEARS"
  }
}

resource "aws_lambda_code_signing_config" "visitor_counter_csc" {
  allowed_publishers {
    signing_profile_version_arns = [
      aws_signer_signing_profile.visitor_counter_sp.version_arn
    ]
  }

  policies {
    untrusted_artifact_on_deployment = "Enforce"
  }
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "archive_file" "lambda_handler" {
  type = "zip"

  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/../src.zip"
  excludes    = ["${path.module}/../src/__pycache__", "${path.module}/../src/__init__.py"]
}

resource "aws_s3_object" "unsigned_zip" {
  key         = "terraform/lambda/src.zip"
  bucket      = "jmkriz"
  source      = "${path.module}/../src.zip"
  source_hash = data.archive_file.lambda_handler.output_base64sha256
}

resource "aws_signer_signing_job" "visitor_counter_sj" {
  profile_name = aws_signer_signing_profile.visitor_counter_sp.name

  source {
    s3 {
      bucket  = aws_s3_object.unsigned_zip.bucket
      key     = aws_s3_object.unsigned_zip.key
      version = aws_s3_object.unsigned_zip.version_id
    }
  }

  destination {
    s3 {
      bucket = aws_s3_object.unsigned_zip.bucket
      prefix = "terraform/lambda/signed/"
    }
  }

  ignore_signing_job_failure = false
}

resource "aws_lambda_function" "visitor_counter" {
  s3_bucket     = "jmkriz"
  s3_key        = aws_signer_signing_job.visitor_counter_sj.signed_object[0]["s3"][0]["key"]
  function_name = "visitor_counter"
  role          = aws_iam_role.iam_for_lambda.arn

  handler = "visitor_counter.lambda_handler"
  runtime = "python3.9"

  code_signing_config_arn = aws_lambda_code_signing_config.visitor_counter_csc.arn
}
