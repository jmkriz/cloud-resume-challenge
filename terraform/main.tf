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

resource "aws_dynamodb_table" "resume_visitor_count" {
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  name         = "resume"

  attribute {
    name = "id"
    type = "S"
  }
}
