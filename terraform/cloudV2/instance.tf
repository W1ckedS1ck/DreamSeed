# Create boot disk
resource "cloudru_evolution_compute_disk" "main" {
  project_id  = var.project_id
  name        = "${var.instance_name}-disk"
  size        = 50
  bootable    = true
  description = "Boot disk for ${var.instance_name}"

  zone_identifier = {
    name = var.zone
  }

  disk_type_identifier = {
    name = "SSD"
  }
}

# Create VM
resource "cloudru_evolution_compute_vm" "main" {
  project_id  = var.project_id
  name        = var.instance_name
  description = "DreamSeed instance created with Terraform"

  zone_identifier = {
    name = var.zone
  }

  flavor_identifier = {
    name = var.flavor
  }

  disk_identifiers = [{
    disk_id = cloudru_evolution_compute_disk.main.id
  }]

  cloud_init_userdata = base64encode(<<-CLOUDINIT
    #cloud-config
    hostname: ${var.instance_name}
    package_update: true
    packages:
      - curl
      - wget
      - git
    runcmd:
      - echo "DreamSeed instance ready!" > /tmp/ready.txt
  CLOUDINIT
  )
}
