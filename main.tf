provider "aws" {
  region = var.aws_region
}

resource "random_id" "bucket_id" {
  byte_length = 4
}
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_security_group" "ec2_sg" {
  name   = "ec2_sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "project" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.key_pair

  tags = {
    Name = "ProjectEC2"
  }
}

resource "aws_ebs_volume" "extra_storage" {
  availability_zone = aws_instance.project.availability_zone
  size              = 5
}

resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.extra_storage.id
  instance_id = aws_instance.project.id
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy_attachment" "lambda_basic_attach" {
  name       = "lambda-basic-exec"
  roles      = [aws_iam_role.lambda_exec_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
locals {
  lambda_functions = {
    reset = {
      handler = "reset.lambda_handler"
    }
    extend = {
      handler = "extend.lambda_handler"
    }
    scale = {
      handler = "scale.lambda_handler"
    }
  }
}

resource "aws_lambda_function" "functions" {
  for_each = local.lambda_functions

  function_name     = each.key
  filename          = "${path.module}/lambda/${each.key}.zip"
  source_code_hash  = filebase64sha256("${path.module}/lambda/${each.key}.zip")
  handler           = each.value.handler
  runtime           = "python3.8"
  role              = aws_iam_role.lambda_exec_role.arn
  timeout           =  30
  environment {
    variables = {
      INSTANCE_ID = aws_instance.project.id
    }
  }
}

resource "aws_lambda_permission" "allow_api_gateway" {
  for_each = aws_lambda_function.functions
  statement_id  = "AllowExecutionFromAPIGateway-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_api_gateway_rest_api" "main" {
  name = "dashboard-api"
}

resource "aws_api_gateway_resource" "lambda_resource" {
  for_each = aws_lambda_function.functions
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = each.key
}

resource "aws_api_gateway_method" "lambda_post" {
  for_each = aws_api_gateway_resource.lambda_resource
  rest_api_id   = each.value.rest_api_id
  resource_id   = each.value.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  for_each = aws_api_gateway_method.lambda_post
  rest_api_id             = each.value.rest_api_id
  resource_id             = each.value.resource_id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.functions[each.key].arn}/invocations"
}

resource "aws_api_gateway_deployment" "deploy" {
  depends_on = [aws_api_gateway_integration.lambda_integration]
  rest_api_id = aws_api_gateway_rest_api.main.id
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.deploy.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "prod"
}

resource "aws_cloudwatch_metric_alarm" "alarms" {
  for_each = {
    cpu     = { metric = "CPUUtilization", ns = "AWS/EC2", threshold = 70, desc = "CPU usage > 70%" }
    memory  = { metric = "mem_used_percent", ns = "CWAgent", threshold = 70, desc = "Memory usage > 70%" }
    disk    = { metric = "disk_used_percent", ns = "CWAgent", threshold = 70, desc = "Disk usage > 70%" }
    network = { metric = "NetworkIn", ns = "AWS/EC2", threshold = 104857600, desc = "Network In > 100MB" }
  }
  alarm_name          = "${each.key}-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = each.value.metric
  namespace           = each.value.ns
  period              = 60
  statistic           = "Average"
  threshold           = each.value.threshold
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    InstanceId = aws_instance.project.id
  }
  alarm_description = each.value.desc
}

resource "aws_sns_topic" "alerts" {
  name = "dashboard-alerts"
}

resource "aws_sns_topic_subscription" "sms" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = "+919087827374"
}

resource "aws_cognito_user_pool" "user_pool" {
  name = "dashboard-users"
}

resource "aws_cognito_user_pool_client" "user_pool_client" {
  name            = "web-client"
  user_pool_id    = aws_cognito_user_pool.user_pool.id
  generate_secret = false
}

resource "aws_cognito_user_group" "admin_group" {
  user_pool_id = aws_cognito_user_pool.user_pool.id
  name         = "admin"
  description  = "Control node users"
  precedence   = 1
}

resource "aws_cognito_user" "dashboard_user" {
  user_pool_id         = aws_cognito_user_pool.user_pool.id
  username             = "admin"
  force_alias_creation = false
  message_action       = "SUPPRESS"
  attributes = {
    email        = "kishoresuzil1005@gmail.com"
    phone_number = "+919087827374"
  }
}

resource "null_resource" "admin_group_add" {
  provisioner "local-exec" {
    command = <<EOT
      aws cognito-idp admin-add-user-to-group \
        --user-pool-id ${aws_cognito_user_pool.user_pool.id} \
        --username ${aws_cognito_user.dashboard_user.username} \
        --group-name ${aws_cognito_user_group.admin_group.name}
    EOT
  }
  triggers = {
    user = aws_cognito_user.dashboard_user.id
  }
}

resource "aws_s3_bucket" "dashboard" {
  bucket         = "dashboard-bucket-${random_id.bucket_id.hex}"
  force_destroy  = true
}

resource "aws_s3_bucket_public_access_block" "dashboard_bucket_block" {
  bucket = aws_s3_bucket.dashboard.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_policy" "dashboard_public" {
  bucket = aws_s3_bucket.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = "*",
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.dashboard.arn}/*"
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.dashboard_bucket_block
  ]
}

resource "aws_s3_object" "dashboard_files" {
  for_each = fileset("${path.module}/project-dashboard", "**")

  bucket       = aws_s3_bucket.dashboard.id
  key          = each.key
  source       = "${path.module}/project-dashboard/${each.key}"
  content_type = lookup(
    { html = "text/html", css = "text/css", js = "application/javascript" },
    split(".", each.key)[length(split(".", each.key)) - 1],
    "text/plain"
  )
}

