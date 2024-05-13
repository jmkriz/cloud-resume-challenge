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

data "aws_iam_policy_document" "access_visitor_count_doc" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    resources = [aws_dynamodb_table.resume_visitor_count.arn]
  }
}

resource "aws_iam_policy" "access_visitor_count" {
  name        = "access-visitor-count"
  description = "Policy for Lambda to access the visitor count"
  policy      = data.aws_iam_policy_document.access_visitor_count_doc.json
}

resource "aws_iam_role_policy_attachment" "visitor_count_attachment" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.access_visitor_count.arn
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

# REST API Gateway to call Lambda function
resource "aws_api_gateway_rest_api" "visitor_counter" {
  name = "visitor_count"
}

resource "aws_api_gateway_resource" "visitor_counter_resource" {
  rest_api_id = aws_api_gateway_rest_api.visitor_counter.id
  parent_id   = aws_api_gateway_rest_api.visitor_counter.root_resource_id
  path_part   = "visitorcount"
}

resource "aws_api_gateway_method" "get_visitor_count" {
  rest_api_id   = aws_api_gateway_rest_api.visitor_counter.id
  resource_id   = aws_api_gateway_resource.visitor_counter_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "increment_visitor_count" {
  rest_api_id   = aws_api_gateway_rest_api.visitor_counter.id
  resource_id   = aws_api_gateway_resource.visitor_counter_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_visitor_count_integration" {
  rest_api_id             = aws_api_gateway_rest_api.visitor_counter.id
  resource_id             = aws_api_gateway_resource.visitor_counter_resource.id
  http_method             = aws_api_gateway_method.get_visitor_count.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.visitor_counter.invoke_arn
}

resource "aws_api_gateway_integration" "increment_visitor_count_integration" {
  rest_api_id             = aws_api_gateway_rest_api.visitor_counter.id
  resource_id             = aws_api_gateway_resource.visitor_counter_resource.id
  http_method             = aws_api_gateway_method.increment_visitor_count.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.visitor_counter.invoke_arn
}

resource "aws_lambda_permission" "visitor_counter_lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.visitor_counter.execution_arn}/*"
}

resource "aws_api_gateway_deployment" "visitor_counter_deployment" {
  rest_api_id = aws_api_gateway_rest_api.visitor_counter.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.visitor_counter_resource.id,
      aws_api_gateway_method.get_visitor_count.id,
      aws_api_gateway_method.increment_visitor_count.id,
      aws_api_gateway_integration.get_visitor_count_integration.id,
      aws_api_gateway_integration.increment_visitor_count_integration.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "visitor_counter_stage" {
  deployment_id = aws_api_gateway_deployment.visitor_counter_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.visitor_counter.id
  stage_name    = "visitor_counter"
}

# S3 Website
resource "aws_s3_bucket" "bucket" {
  bucket = "jmkriz-frontend"
}

resource "aws_s3_bucket_public_access_block" "public-access-block" {
  bucket                  = aws_s3_bucket.bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "policy" {
  bucket = aws_s3_bucket.bucket.id
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Sid" : "PublicReadGetObject",
          "Effect" : "Allow",
          "Principal" : "*",
          "Action" : "s3:GetObject",
          "Resource" : "arn:aws:s3:::${aws_s3_bucket.bucket.id}/*"
        }
      ]
    }
  )

  # Require public access blocks be removed before applying policy
  depends_on = [
    aws_s3_bucket_public_access_block.public-access-block
  ]
}

resource "aws_s3_bucket_website_configuration" "front_end" {
  bucket = aws_s3_bucket.bucket.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_object" "index" {
  bucket = aws_s3_bucket.bucket.bucket
  key    = "index.html"
  source = "../frontend/index.html"
}

resource "aws_s3_object" "styles" {
  bucket = aws_s3_bucket.bucket.bucket
  key    = "styles.css"
  source = "../frontend/styles.css"
}

# CloudFront distribution and DNS

locals {
  s3_origin_id       = "s3_bucket"
  api_origin_id      = "api_gateway"
  custom_domain_name = "jmkriz.dev"
}

resource "aws_acm_certificate" "cert" {
  domain_name               = local.custom_domain_name
  subject_alternative_names = ["www.${local.custom_domain_name}", "api.${local.custom_domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "frontend_zone" {
  name = local.custom_domain_name
}

resource "aws_route53_record" "frontend_dns" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.frontend_zone.zone_id
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.frontend_dns : record.fqdn]
}

resource "aws_cloudfront_distribution" "frontend_distribution" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
  }

  default_cache_behavior {
    allowed_methods  = ["HEAD", "GET", "OPTIONS"]
    cached_methods   = ["HEAD", "GET", "OPTIONS"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      locations        = []
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = aws_acm_certificate.cert.arn
    cloudfront_default_certificate = false
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.custom_domain_name, "www.${local.custom_domain_name}"]
  price_class         = "PriceClass_100"
}

resource "aws_api_gateway_domain_name" "api" {
  certificate_arn = aws_acm_certificate_validation.cert_validation.certificate_arn
  domain_name     = "api.${local.custom_domain_name}"
}

resource "aws_api_gateway_base_path_mapping" "api_mapping" {
  api_id      = aws_api_gateway_rest_api.visitor_counter.id
  stage_name  = aws_api_gateway_stage.visitor_counter_stage.stage_name
  domain_name = aws_api_gateway_domain_name.api.domain_name
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.frontend_zone.zone_id
  name    = "www.${local.custom_domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.frontend_distribution.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.frontend_zone.zone_id
  name    = local.custom_domain_name
  type    = "A"

  alias {
    name                   = aws_route53_record.www.name
    zone_id                = aws_route53_record.www.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.frontend_zone.zone_id
  name    = aws_api_gateway_domain_name.api.domain_name
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.api.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.api.cloudfront_zone_id
    evaluate_target_health = true
  }
}
