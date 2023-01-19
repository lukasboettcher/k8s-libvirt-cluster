# set-up terraform and libvirt provider
terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# local variables that set the number of master and worker nodes
locals {
  masternodes        = 1
  workernodes        = 2
  subnet_node_prefix = "172.16.1"
}

# create libvirt pool and images based on ubuntu jammy
resource "libvirt_pool" "local" {
  name = "ubuntu"
  type = "dir"
  path = "/tmp/terraform-libvirt-pool-ubuntu"
}

resource "libvirt_volume" "ubuntu2204_cloud" {
  name   = "ubuntu22.04.qcow2"
  pool   = libvirt_pool.local.name
  source = "https://cloud-images.ubuntu.com/minimal/releases/focal/release/ubuntu-20.04-minimal-cloudimg-amd64.img"
  format = "qcow2"
}

resource "libvirt_volume" "ubuntu2204_resized" {
  name           = "ubuntu-volume-${count.index}"
  base_volume_id = libvirt_volume.ubuntu2204_cloud.id
  pool           = libvirt_pool.local.name
  size           = 10 * 1024 * 1024 * 1024 // 10GiB volume based on cloud image
  count          = local.masternodes + local.workernodes
}

# cloud init config files are read here
data "template_file" "public_key" {
  template = file("~/.ssh/id_rsa.pub")
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config.cfg")
}

resource "random_password" "k3s_token" {
  length  = 48
  upper   = false
  special = false
}

data "template_file" "master_user_data" {
  count    = local.masternodes
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    public_key      = data.template_file.public_key.rendered
    hostname        = "k8s-master-${count.index + 1}"
    k3s_install_cmd = "curl -sfL https://get.k3s.io | K3S_TOKEN=${random_password.k3s_token.result} sh -"
  }
}

data "template_file" "worker_user_data" {
  count    = local.workernodes
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    public_key      = data.template_file.public_key.rendered
    hostname        = "k8s-worker-${count.index + 1}"
    k3s_install_cmd = "curl -sfL https://get.k3s.io | K3S_URL=https://${libvirt_domain.k8s_masters[0].network_interface[0].addresses[0]}:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
  }
}

resource "libvirt_cloudinit_disk" "masternodes" {
  count          = local.masternodes
  name           = "cloudinit_master_resized_${count.index}.iso"
  pool           = libvirt_pool.local.name
  user_data      = data.template_file.master_user_data[count.index].rendered
  network_config = data.template_file.network_config.rendered
}

resource "libvirt_cloudinit_disk" "workernodes" {
  count          = local.workernodes
  name           = "cloudinit_worker_resized_${count.index}.iso"
  pool           = libvirt_pool.local.name
  user_data      = data.template_file.worker_user_data[count.index].rendered
  network_config = data.template_file.network_config.rendered
}

# create libvirt resources (network and domains)
resource "libvirt_network" "kube_node_network" {
  name      = "kube_nodes"
  mode      = "nat"
  domain    = "k8s.local"
  autostart = true
  addresses = ["${local.subnet_node_prefix}.0/24"]
  dns {
    enabled = true
  }
}

resource "libvirt_domain" "k8s_masters" {
  count  = local.masternodes
  name   = "k8s-master-${count.index + 1}"
  memory = "1024"
  vcpu   = 1

  cloudinit = libvirt_cloudinit_disk.masternodes[count.index].id

  network_interface {
    network_id     = libvirt_network.kube_node_network.id
    hostname       = "k8s-master-${count.index + 1}"
    addresses      = ["${local.subnet_node_prefix}.1${count.index + 1}"]
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.ubuntu2204_resized[count.index].id
  }

  # console {
  #   type        = "pty"
  #   target_type = "serial"
  #   target_port = "0"
  # }

  # graphics {
  #   type        = "spice"
  #   listen_type = "address"
  #   autoport    = true
  # }
}

resource "libvirt_domain" "k8s_workers" {
  count  = local.workernodes
  name   = "k8s-worker-${count.index + 1}"
  memory = "1024"
  vcpu   = 1

  cloudinit = libvirt_cloudinit_disk.workernodes[count.index].id

  network_interface {
    network_id     = libvirt_network.kube_node_network.id
    hostname       = "k8s-worker-${count.index + 1}"
    addresses      = ["${local.subnet_node_prefix}.2${count.index + 1}"]
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.ubuntu2204_resized[local.masternodes + count.index].id
  }

  # console {
  #   type        = "pty"
  #   target_type = "serial"
  #   target_port = "0"
  # }

  # graphics {
  #   type        = "spice"
  #   listen_type = "address"
  #   autoport    = true
  # }
}

output "master_ip" {
  value = "${libvirt_domain.k8s_masters[0].network_interface[0].addresses[0]}"
}
