variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. Null uses the default credential chain."
  type        = string
  default     = null
}

variable "aws_account_id" {
  description = "The only account this configuration may run against (12-digit ID)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as a prefix for related resources."
  type        = string
  default     = "webinar-kata"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.35"
}

# Network

variable "create_vpc" {
  description = "Create a VPC with 2 AZs, private and public subnets, and one NAT gateway. Set false to use an existing VPC."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR of the created VPC."
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "vpc_id" {
  description = "Existing VPC ID. Only used when create_vpc = false."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (with NAT egress). Only used when create_vpc = false."
  type        = list(string)
  default     = []
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Node groups

variable "kata_instance_type" {
  description = "Instance type for the Kata node group. Must support nested virtualization."
  type        = string
  default     = "m8i.xlarge"
}

variable "kata_min_size" {
  type    = number
  default = 0
}

variable "kata_desired_size" {
  type    = number
  default = 1
}

variable "kata_max_size" {
  type    = number
  default = 2
}

variable "system_instance_type" {
  description = "Instance type for the system node group."
  type        = string
  default     = "t3.medium"
}

variable "system_desired_size" {
  type    = number
  default = 1
}

variable "admin_principal_arns" {
  description = "Additional IAM principals to grant cluster-admin. The creator always has admin."
  type        = list(string)
  default     = []
}

# Custom guest kernel

variable "kata_guest_kernel_s3_uri" {
  description = <<-EOT
    s3://bucket/key of the Landlock guest kernel built by kernel/. Kata nodes
    download it to /opt/kata-guest-kernel/vmlinux-landlock at boot. Use a new
    key for each kernel, since changing the URI rolls the node group.
  EOT
  type        = string

  validation {
    condition     = can(regex("^s3://[^/]+/.+", var.kata_guest_kernel_s3_uri))
    error_message = "kata_guest_kernel_s3_uri must be s3://bucket/key."
  }
}

# ECR

variable "ecr_repository_name" {
  type    = string
  default = "amazon-webinar-demo"
}
