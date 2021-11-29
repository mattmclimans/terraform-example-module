resource "google_compute_instance" "main" {
  for_each = var.instances

  name                      = each.value.name
  zone                      = each.value.zone
  machine_type              = var.machine_type
  min_cpu_platform          = var.min_cpu_platform
  labels                    = var.labels
  tags                      = var.tags
  metadata_startup_script   = var.metadata_startup_script
  project                   = var.project
  resource_policies         = var.resource_policies
  can_ip_forward            = true
  allow_stopping_for_update = true

  metadata = merge({
    mgmt-interface-swap                  = "enable"
    vmseries-bootstrap-gce-storagebucket = each.value.bootstrap_bucket 
    #vmseries-bootstrap-gce-storagebucket = var.bootstrap_bucket
    serial-port-enable                   = true
    ssh-keys                             = var.ssh_key
  }, var.metadata)

  service_account {
    email  = var.service_account
    scopes = var.scopes
  }

  dynamic "network_interface" {
    for_each = each.value.network_interfaces

    content {
      network_ip = local.dyn_interfaces[each.key][network_interface.key].network_ip
      subnetwork = network_interface.value.subnetwork

      dynamic "access_config" {
        # The "access_config", if present, creates a public IP address. Currently GCE only supports one, hence "one".
        for_each = try(network_interface.value.public_nat, false) ? ["one"] : []
        content {
          nat_ip                 = local.dyn_interfaces[each.key][network_interface.key].nat_ip
          public_ptr_domain_name = local.dyn_interfaces[each.key][network_interface.key].public_ptr_domain_name
        }
      }

      dynamic "alias_ip_range" {
        for_each = try(network_interface.value.alias_ip_range, [])
        content {
          ip_cidr_range         = alias_ip_range.value.ip_cidr_range
          subnetwork_range_name = try(alias_ip_range.value.subnetwork_range_name, null)
        }
      }
    }
  }

  # TODO: var.linux_fake  -> 0.0/0 route for both nic0 and nic1 -> ip vrf add nic1 ; ip ro add 0.0.0.0/0

  boot_disk {
    initialize_params {
      image = "${var.image_prefix_uri}${var.image_name}"
      type  = var.disk_type
    }
  }

  depends_on = []
}

// The Deployment Guide Jan 2020 recommends per-zone instance groups (instead of regional IGMs).
resource "google_compute_instance_group" "main" {
  for_each = var.create_instance_group ? var.instances : {}

  name      = "${each.value.name}-${each.value.zone}-ig"
  zone      = each.value.zone
  project   = var.project
  instances = [google_compute_instance.main[each.key].self_link]

  dynamic "named_port" {
    for_each = var.named_ports
    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }
}


# Using the default ephemeral IPs on a firewall is a bad idea, because GCE often changes them.
# While some users will just provide explicit static IP addresses (like "192.168.2.22"), we will accommodate 
# also the remaining users - those who'd like to have dynamic IP addresses.
#
# We use here google_compute_address to reserve a dynamically assigned IP address as a named entity.
# Such address will not change even if the virtual machine is stopped or removed.

locals {
  # Terraform for_each unfortunately requires a single-dimensional map, but we have
  # a two-dimensional input. We need two steps for conversion.
  #
  # First, flatten() ensures that this local value is a flat list of objects, rather
  # than a list of lists of objects.
  input_flat_interfaces = flatten([
    for instance_key, instance in var.instances : [
      for nic_key, nic in instance.network_interfaces : {
        instance_key = instance_key
        instance     = instance
        nic_key      = nic_key
        nic          = nic
      }
    ]
  ])

  # Convert flat list to a flat map. Make sure the keys are unique. This is used for for_each.
  input_interfaces = { for v in local.input_flat_interfaces : "${v.instance_key}-${v.nic_key}" => v }

  # The for_each will consume a flat map and produce a new flat map of dynamically-created resources.
  # As a final step, gather results back into a handy two-dimensional map.
  # Create a usable result - augument the input with our dynamically created resources.
  dyn_interfaces = { for instance_key, instance in var.instances :
    instance_key => {
      for nic_key, nic in instance.network_interfaces :
      nic_key => {
        network_ip = google_compute_address.private["${instance_key}-${nic_key}"].address
        nat_ip = (
          # If we have been given an excplicit nat_ip, use it. Else, use our own named address.
          try(nic.nat_ip, null) != null ?
          nic.nat_ip
          :
          try(google_compute_address.public["${instance_key}-${nic_key}"].address, null)
        )
        public_ptr_domain_name = try(nic.public_ptr_domain_name, null)
      }
    }
  }
}

data "google_compute_subnetwork" "main" {
  for_each = local.input_interfaces

  self_link = each.value.nic.subnetwork
}

resource "google_compute_address" "private" {
  for_each = local.input_interfaces

  name = try(
    each.value.nic.address_name,
    "${each.value.instance.name}-nic${each.value.nic_key}",
  )
  address_type = "INTERNAL"
  address      = try(each.value.nic.ip_address, null)
  subnetwork   = each.value.nic.subnetwork
  region       = data.google_compute_subnetwork.main[each.key].region
}

resource "google_compute_address" "public" {
  for_each = { for k, v in local.input_interfaces : k => v if v.nic.public_nat && try(v.nic.nat_ip, null) == null }

  name = try(
    each.value.nic.public_address_name,
    "${each.value.instance.name}-nic${each.value.nic_key}-public",
  )
  address_type = "EXTERNAL"
  region       = data.google_compute_subnetwork.main[each.key].region
}
