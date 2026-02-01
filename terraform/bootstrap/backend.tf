terraform {
  backend "s3" {
    bucket = "cloudsentinel-terraform-state-8fb8bf92"
    key    = "env/dev/terraform.tfstate"
    region = "us-east-2"
    dynamodb_table = "terraform-locks-74c26fe8"
    encrypt = true
  }
}