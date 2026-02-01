variable "name" {
    description = "The name of the VPC"
    type        = string
}

variable "cidr" {
    description = "The CIDR block for the VPC"
    type        = string
}

variable "azs" {
    description = "A list of availability zones in the region"
    type        = list(string)
}