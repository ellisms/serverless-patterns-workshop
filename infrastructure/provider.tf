# AWS provider configuration.
#
# No region is set here on purpose: the provider resolves its region from the
# active AWS profile / the AWS_REGION environment variable. Never hardcode a
# region in Terraform.
provider "aws" {
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
    }
  }
}

# The archive and null providers require no configuration. They are declared in
# versions.tf and used by the Lambda packaging steps (null_resource build +
# archive_file zip) in later infrastructure files.
provider "archive" {}

provider "null" {}
