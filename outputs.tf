output "cognito_user_pool_id" {
  description = "Cognito user pool ID"
  value       = aws_cognito_user_pool.user_pool.id
}

output "cognito_user_pool_client_id" {
  description = "Cognito user pool client ID"
  value       = aws_cognito_user_pool_client.user_pool_client.id
}

output "dashboard_url" {
  description = "S3 website URL for the dashboard"
  value       = aws_s3_bucket_website_configuration.dashboard.website_endpoint
}

output "lambda_function_names" {
  description = "Deployed Lambda function names"
  value       = { for name, fn in aws_lambda_function.functions : name => fn.function_name }
}

output "cpu_alarm_id" {
  description = "CloudWatch Alarm ID for CPU"
  value       = aws_cloudwatch_metric_alarm.alarms["cpu"].id
}

