#  terraform {
#  backend "gcs" {
#    bucket  = "gcs-rkk-statefile"
#    prefix  = "terraform/state"
#  }
# }
resource "google_project_service" "cloud_resource_manager_api" {
  project = var.project_id  
  service = "cloudresourcemanager.googleapis.com"
}
resource "google_project_service" "service_networking_api" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"
}
resource "google_project_service" "service_usage_api" {
  project = var.project_id
  service = "serviceusage.googleapis.com"
}
resource "google_project_service" "iam_api" {
  project = var.project_id 
  service = "iam.googleapis.com"
}
resource "google_project_service" "kubernetes_engine_api" {
  project = var.project_id
  service = "container.googleapis.com"
}
resource "google_project_service" "compute_engine" {
  project = var.project_id
  service = "compute.googleapis.com"
}
resource "google_project_service" "cloud_sql_api" {
  project = var.project_id
  service = "sqladmin.googleapis.com"
}


# Creating Custom Vpc under 10.0.16.0/20
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  lifecycle {
      postcondition {
        condition = self.id != null
        error_message = "Error while creating app vpc"
      }
    }
}

# # Creation of subnet
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.subnet_cidr
  lifecycle {
      precondition {
        condition = google_compute_network.vpc.id != null
        error_message = "VPC must exist to create a subnet "
      }
    }
    depends_on = [ google_compute_network.vpc ]
}

#Private space within vpc
resource "google_compute_global_address" "private_ip_block" {
  name         = "private-ip-block"
  purpose      = "VPC_PEERING"
  address_type = "INTERNAL"
  ip_version   = "IPV4"
  prefix_length = 20
  network       = google_compute_network.vpc.self_link
   lifecycle {
      precondition {
        condition = google_compute_network.vpc.id != null
        error_message = "VPC must exist before creating a private space"
      }
    }
    depends_on = [ google_compute_network.vpc ]
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
  lifecycle {
      precondition {
        condition = google_compute_global_address.private_ip_block.id != null
        error_message = "Private Ip block is not created i.e peering is not generated"
      }
    }
    depends_on = [ google_compute_global_address.private_ip_block ]
}


# Creation of GKE cluster with 1 nodes in our custom VPC/Subnet
resource "google_container_cluster" "primary" {
  name                     = var.kubernetes_cluster_name
  location                 = var.location
  network                  = google_compute_network.vpc.name
  subnetwork               = google_compute_subnetwork.subnet.name
  initial_node_count       = 1
  deletion_protection = false
  
  private_cluster_config {
    enable_private_endpoint = true
    enable_private_nodes   = true 
    master_ipv4_cidr_block = "10.13.0.0/28"
  }
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "10.11.0.0/21"
    services_ipv4_cidr_block = "10.12.0.0/21"
  }
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.0.7/32"
      display_name = "net1"
    }

  }

   lifecycle {
      precondition {
        condition = google_compute_network.vpc.id != null
        error_message = "VPC must exist for cluster creation"
      }
      precondition {
        condition = google_compute_subnetwork.subnet.id != null
        error_message = "Subnet is required for creating a private cluster"
      }
    }
    depends_on = [ google_compute_network.vpc , google_compute_subnetwork.subnet]
}


resource "google_compute_address" "my_internal_ip_addr" {
  project      = var.project_id
  address_type = "INTERNAL"
  region       = var.region
  subnetwork   = var.subnet_name
  name         = "my-ip"
  address      = "10.0.16.10"
  description  = "Internal IP "
}

resource "google_compute_instance" "default" {
  project      = var.project_id
  zone         = var.location
  name         = var.instance_name
  machine_type = "e2-medium"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }
  network_interface {
    network    = var.vpc_name
    subnetwork = var.subnet_name 
    network_ip = google_compute_address.my_internal_ip_addr.address
  }
  lifecycle {
    prevent_destroy = false
  }

}

#allow-ssh
resource "google_compute_firewall" "rules" {
  project = var.project_id
  name    = "allow-ssh"
  network = var.vpc_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}

#Creating IAP SSH permissions for TunnelResource accessor for the test instance

resource "google_project_iam_member" "project" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:174291680877-compute@developer.gserviceaccount.com"
}

# cloud router for nat gateway
resource "google_compute_router" "router" {
  project = var.project_id
  name    = "nat-router"
  network = var.vpc_name
  region  = var.region
}

#Nat Gateway with module

module "cloud-nat" {
  source     = "terraform-google-modules/cloud-nat/google"
  version    = "~> 1.2"
  project_id = var.project_id
  region     = var.region
  router     = google_compute_router.router.name
  name       = "nat-config"

}

#Creation of Cloud SQL 
resource "google_sql_database" "main" {
  name     = var.db_name
  instance = google_sql_database_instance.main_primary.name
}
resource "google_sql_database_instance" "main_primary" {
  name             = var.db_instance_name
  database_version = var.db_version
  depends_on       = [google_service_networking_connection.private_vpc_connection]
  settings {
    tier              = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_size         = 10  
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_address.my_internal_ip_addr.address
    }
  }
}

#Configuring DB user
resource "google_sql_user" "db_user" {
  name     = var.user
  instance = google_sql_database_instance.main_primary.name
  password = var.password
  lifecycle {
      precondition {
        condition = google_sql_database_instance.main_primary.id != null
        error_message = "SQL instance is required to create a user"
      }
    }
    depends_on = [ google_sql_database_instance.main_primary]
}







# # Creating Custom Vpc under 10.0.16.0/20
# resource "google_compute_network" "vpc" {
#   name                    = "vpc1"
#   auto_create_subnetworks = false
#    lifecycle {
#       postcondition {
#         condition = self.id != null
#         error_message = "Error while creating app vpc"
#       }
#     }
# }

# # Creation of subnet
# resource "google_compute_subnetwork" "subnet" {
#   name          = "subnet1"
#   region        = "asia-south2"
#   network       = google_compute_network.vpc.name
#   ip_cidr_range = "10.0.16.0/20"
#   lifecycle {
#       precondition {
#         condition = google_compute_network.vpc.id != null
#         error_message = "VPC must exist to create a subnet "
#       }
#     }
#     depends_on = [ google_compute_network.vpc ]
# }

# #Private space within vpc
# resource "google_compute_global_address" "private_ip_block" {
#   name         = "private-ip-block"
#   purpose      = "VPC_PEERING"
#   address_type = "INTERNAL"
#   ip_version   = "IPV4"
#   prefix_length = 20
#   network       = google_compute_network.vpc.self_link
#   lifecycle {
#       precondition {
#         condition = google_compute_network.vpc.id != null
#         error_message = "VPC must exist before creating a private space"
#       }
#     }
#     depends_on = [ google_compute_network.vpc ]
# }


# #Creation of Private space within the custom vpc
# resource "google_service_networking_connection" "private_vpc_connection" {
#   network                 = google_compute_network.vpc.self_link
#   service                 = "servicenetworking.googleapis.com"
#   reserved_peering_ranges = [google_compute_global_address.private_ip_block.name]
#    lifecycle {
#       precondition {
#         condition = google_compute_global_address.private_ip_block.id != null
#         error_message = "Private Ip block is not created i.e peering is not generated"
#       }
#     }
#     depends_on = [ google_compute_global_address.private_ip_block ]
  
# }

# # Creation of GKE cluster with 1 node in the custom VPC/Subnet
# resource "google_container_cluster" "primary" {
#   name                     = "my-gke-cluster"
#   location                 = "asia-south2-a"
#   network                  = google_compute_network.vpc.name
#   subnetwork               = google_compute_subnetwork.subnet.name
#   initial_node_count       = 1
  
#   private_cluster_config {
#     enable_private_endpoint = true
#     enable_private_nodes   = true 
#     master_ipv4_cidr_block = "10.13.0.0/28"
#   }
#   ip_allocation_policy {
#     cluster_ipv4_cidr_block  = "10.11.0.0/21"
#     services_ipv4_cidr_block = "10.12.0.0/21"
#   }
#   master_authorized_networks_config {
#     cidr_blocks {
#       cidr_block   = "10.0.0.7/32"
#       display_name = "net1"
#     }

#   }
#   lifecycle {
#       precondition {
#         condition = google_compute_network.vpc.id != null
#         error_message = "VPC must exist for cluster creation"
#       }
#       precondition {
#         condition = google_compute_subnetwork.subnet.id != null
#         error_message = "Subnet is required for creating a private cluster"
#       }
#     }
#     depends_on = [ google_compute_network.vpc , google_compute_subnetwork.subnet]
# }


# #Internal IP configuration for creation of private SQL instance
# resource "google_compute_address" "my_internal_ip_addr" {
#   project      = "april-proj"
#   address_type = "INTERNAL"
#   region       = "asia-south2"
#   subnetwork   = "subnet1"
#   name         = "my-ip"
#   address      = "10.0.16.10"
#   description  = "Internal IP "
# }


# #Creating an instance and establishing a connection with cluster for deployment
# resource "google_compute_instance" "default" {
#   project      = "april-proj"
#   zone         = "asia-south2-a"
#   name         = "compute-instance"
#   machine_type = "e2-medium"

#   boot_disk {
#     initialize_params {
#       image = "debian-cloud/debian-11"
#     }
#   }
#   network_interface {
#     network    = "vpc1"
#     subnetwork = "subnet1" 
#     network_ip = google_compute_address.my_internal_ip_addr.address
#   }

# }

# #allow-ssh
# resource "google_compute_firewall" "rules" {
#   project = "april-proj"
#   name    = "allow-ssh"
#   network = "vpc1" 

#   allow {
#     protocol = "tcp"
#     ports    = ["22"]
#   }
#   source_ranges = ["35.235.240.0/20"]
# }

# # Creating IAP SSH permissions for TunnelResource accessor for the VM test instance

# resource "google_project_iam_member" "project" {
#   project = "april-proj"
#   role    = "roles/iap.tunnelResourceAccessor"
#   member  = "serviceAccount:174291680877-compute@developer.gserviceaccount.com"
# }

# # cloud router for nat gateway
# resource "google_compute_router" "router" {
#   project = "april-proj"
#   name    = "nat-router"
#   network = "vpc1"
#   region  = "asia-south2"
# }

# #Nat Gateway with module

# module "cloud-nat" {
#   source     = "terraform-google-modules/cloud-nat/google"
#   version    = "~> 1.2"
#   project_id = "april-proj"
#   region     = "asia-south2"
#   router     = google_compute_router.router.name
#   name       = "nat-config"

# }

# #Creation of Cloud SQL 
# resource "google_sql_database" "main" {
#   name     = "main"
#   instance = google_sql_database_instance.main_primary.name
# }
# resource "google_sql_database_instance" "main_primary" {
#   name             = "main-primary"
#   database_version = "POSTGRES_13"
#   depends_on       = [google_service_networking_connection.private_vpc_connection]
#   settings {
#     tier              = "db-f1-micro"
#     availability_type = "REGIONAL"
#     disk_size         = 10  
#     ip_configuration {
#       ipv4_enabled    = false
#       private_network = google_compute_network.vpc.self_link
#     }
#   }
  
# }

# #Configuring DB user
# resource "google_sql_user" "db_user" {
#   name     = var.user
#   instance = google_sql_database_instance.main_primary.name
#   password = var.password
#   lifecycle {
#       precondition {
#         condition = google_sql_database_instance.main_primary.id != null
#         error_message = "SQL instance is required to create a user"
#       }
#     }
#     depends_on = [ google_sql_database_instance.main_primary]
# }