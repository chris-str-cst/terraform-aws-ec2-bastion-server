locals {
  create_instance_profile = module.this.enabled && try(length(var.instance_profile), 0) == 0
  instance_profile        = local.create_instance_profile ? join("", aws_iam_instance_profile.default.*.name) : var.instance_profile
  eip_enabled             = var.associate_public_ip_address && var.assign_eip_address && module.this.enabled
  security_group_enabled  = module.this.enabled && var.security_group_enabled
  public_dns              = local.eip_enabled ? local.public_dns_rendered : join("", aws_instance.default.*.public_dns)
  public_dns_rendered = local.eip_enabled ? format("ec2-%s.%s.amazonaws.com",
    replace(join("", aws_eip.default.*.public_ip), ".", "-"),
    data.aws_region.default.name == "us-east-1" ? "compute-1" : format("%s.compute", data.aws_region.default.name)
  ) : null
}

data "aws_region" "default" {}

data "aws_ami" "default" {
  most_recent = "true"

  dynamic "filter" {
    for_each = var.ami_filter
    content {
      name   = filter.key
      values = filter.value
    }
  }

  owners = var.ami_owners
}

module "security_group" {
  source  = "cloudposse/security-group/aws"
  version = "0.3.1"

  use_name_prefix = var.security_group_use_name_prefix
  rules           = var.security_group_rules
  description     = var.security_group_description
  vpc_id          = var.vpc_id

  enabled = local.security_group_enabled
  context = module.this.context
}

data "aws_route53_zone" "domain" {
  count   = module.this.enabled && try(length(var.zone_id), 0) > 0 ? 1 : 0
  zone_id = var.zone_id
}

data "template_file" "user_data" {
  count    = module.this.enabled ? 1 : 0
  template = file("${path.module}/${var.user_data_template}")

  vars = {
    user_data   = join("\n", var.user_data)
    ssm_enabled = var.ssm_enabled
    ssh_user    = var.ssh_user
  }
}
module "autoscale_group" {
  source = "cloudposse/ec2-autoscale-group/aws"
  version = "0.27.0"

  count                       = module.this.enabled ? 1 : 0

  image_id                     = data.aws_ami.default.id
  instance_type                = var.instance_type
  user_data_base64             = length(var.user_data_base64) > 0 ? var.user_data_base64 : base64encode(data.template_file.user_data[0].rendered)
  subnet_ids                   = var.subnets[0]
  security_group_ids           = compact(concat(module.security_group.*.id, var.security_groups))
  iam_instance_profile_name    = local.instance_profile
  associate_public_ip_address  = var.associate_public_ip_address
  key_name                    = var.key_name
  enable_monitoring                  = var.monitoring
  disable_api_termination     = var.disable_api_termination

  autoscaling_policies_enabled = false
  default_alarms_enabled       = false
  block_device_mappings        = var.block_device_mappings
  min_size                     = var.min_size
  max_size                     = var.max_size
  metadata_http_endpoint_enabled = (var.metadata_http_endpoint_enabled) ? "enabled" : "disabled"
  metadata_http_put_response_hop_limit = var.metadata_http_put_response_hop_limit
  metadata_http_tokens_required = (var.metadata_http_tokens_required) ? "required" : "optional"

  ebs_optimized                 = var.ebs_optimized

  tags = module.this.tags
}

data "aws_instance" "instance" {
  instance_id = "i-instanceid"

  filter {
    name   = "image-id"
    values = [data.aws_ami.default.id]
  }

  filter {
    name   = "tag:Name"
    values = [var.name]
  }
}

resource "aws_eip" "default" {
  count    = local.eip_enabled ? 1 : 0
  instance = join("", aws_instance.default.*.id)
  vpc      = true
  tags     = module.this.tags
}

module "dns" {
  source   = "cloudposse/route53-cluster-hostname/aws"
  version  = "0.12.0"
  enabled  = module.this.enabled && try(length(var.zone_id), 0) > 0 ? true : false
  zone_id  = var.zone_id
  ttl      = 60
  records  = var.associate_public_ip_address ? tolist([local.public_dns]) : tolist([join("", aws_instance.default.*.private_dns)])
  context  = module.this.context
  dns_name = var.host_name
}
