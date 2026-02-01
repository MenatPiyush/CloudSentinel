variable "name" { 
    type = string 
}
variable "vpc_id" { 
    type = string 
}
variable "private_subnet_ids" { 
    type = list(string) 
}
variable "cluster_version" { 
    type = string 
}
variable "node_instance_types" { 
    type = list(string) 
}