# Infrastructure for the Yandex Cloud Object Storage, Managed Service for MySQL® and Data Transfer
#
# RU: https://cloud.yandex.ru/docs/data-transfer/tutorials/obj-mmy-migration
# EN: https://cloud.yandex.com/en/docs/data-transfer/tutorials/obj-mmy-migration
#
# Specify the following settings:
locals {

  folder_id    = "" # Set your cloud folder ID, same as for provider.
  bucket_name  = "" # Set a unique bucket name.
  mmy_password = "" # Set a password for the MySQL® user.

  # Specify these settings ONLY AFTER the cluster is created. Then run the "terraform apply" command again.
  # You should set up a source endpoint for the Object Storage bucket using the GUI to obtain endpoint's ID.
  source_endpoint_id = "" # Set the source endpoint ID.
  transfer_enabled   = 0  # Set to 1 to enable the transfer.

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mmy-network"        # Name of the network
  subnet_name           = "mmy-subnet-a"       # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"        # CIDR block for the subnet
  sa_name               = "storage-editor"     # Name of the service account
  security_group_name   = "mmy-security-group" # Name of the security group
  mmy_cluster_name      = "mmy-cluster"        # Name of the MySQL® cluster
  mmy_db_name           = "db1"                # Name of the MySQL® database
  mmy_username          = "mmy-user"           # Name of the MySQL® admin user
  target_endpoint_name  = "mmy-target"         # Name of the target endpoint for the MySQL® cluster
  transfer_name         = "s3-mmy-transfer"    # Name of the transfer from the Object Storage bucket to the Managed Service for MySQL® cluster
}

# Network infrastructure for the Managed Service for MySQL® cluster

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for MySQL® cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security_group" {
  description = "Security group for the Managed Service for MySQL® cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allows connections to the cluster from the internet"
    protocol       = "TCP"
    port           = 3306
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Object Storage bucket

# Create a service account.
resource "yandex_iam_service_account" "example-sa" {
  folder_id = local.folder_id
  name      = local.sa_name
}

# Create a static key for the service account.
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.example-sa.id
}

# Grant a role to the service account. The role allows to perform any operations with buckets and objects.
resource "yandex_resourcemanager_folder_iam_binding" "s3-admin" {
  folder_id = local.folder_id
  role      = "storage.editor"

  members = [
    "serviceAccount:${yandex_iam_service_account.example-sa.id}",
  ]
}

# Create a Lockbox secret.
resource "yandex_lockbox_secret" "sa_key_secret" {
  name        = "sa_key_secret"
  description = "Contains a static key pair to create an endpoint"
  folder_id   = local.folder_id
}

# Create a version of Lockbox secret with the static key pair.
resource "yandex_lockbox_secret_version" "first_version" {
  secret_id = yandex_lockbox_secret.sa_key_secret.id
  entries {
    key        = "access_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  }
  entries {
    key        = "secret_key"
    text_value = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  }
}

# Create the Yandex Object Storage bucket.
resource "yandex_storage_bucket" "example-bucket" {
  bucket     = local.bucket_name
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

# Infrastructure for the Managed Service for MySQL® cluster

resource "yandex_mdb_mysql_cluster" "mmy-cluster" {
  name        = local.mmy_cluster_name
  environment = "PRODUCTION"
  network_id  = yandex_vpc_network.network.id
  version     = "8.0"

  resources {
    resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
    disk_type_id       = "network-ssd"
    disk_size          = 10 # GB
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
  }
}

resource "yandex_mdb_mysql_database" "mmy-database" {
  cluster_id = yandex_mdb_mysql_cluster.mmy-cluster.id
  name       = local.mmy_db_name
}

resource "yandex_mdb_mysql_user" "mmy-user" {
  cluster_id = yandex_mdb_mysql_cluster.mmy-cluster.id
  name       = local.mmy_username
  password   = local.mmy_password
  permission {
      database_name = local.mmy_db_name
      roles         = ["ALL"] 
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "mmy_target" {
  description = "Target endpoint for MySQL® cluster"
  name        = local.target_endpoint_name
  settings {
    mysql_target {
      connection {
        mdb_cluster_id = yandex_mdb_mysql_cluster.mmy-cluster.id
      }
      database = local.mmy_db_name
      user     = local.mmy_username
      password {
        raw = local.mmy_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "objstorage-mmy-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the Object Storage bucket to the Managed Service for MySQL® cluster"
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = yandex_datatransfer_endpoint.mmy_target.id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source cluster and start replication
}
