variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "key_pair" {
  description = "EC2 Key pair name"
  type        = string
  default     = "project"
}
variable "aws_region" {
  default = "us-east-1"
}


