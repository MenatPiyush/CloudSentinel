variable "region" { 
    type = string 
    default = "us-east-2" 
}
variable "state_bucket_name" { 
    type = string
    default = "loudsentinel-terraform-state-8fb8bf92"
}
variable "lock_table_name"{ 
    type = string 
    default = "terraform-locks-74c26fe8" 
}