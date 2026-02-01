variable "region" {
    type = string
}
variable "name" {
    type = string
}
variable "vpc_cidr" {
    type = string
}
variable "azs" {
    type = list(string)
}
variable "eks_version" { 
    type = string 
}
variable "node_instance_types" { 
    type = list(string) 
}