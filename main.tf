terraform {
  required_version = ">= 1.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 2.81"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-resources"
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

/*

resource "azurerm_public_ip" "main" {
  name                = "${var.prefix}-publicip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
}

*/

# NAT Gateway

resource "azurerm_public_ip" "natgw_pubip" {
  name                = "nat-gateway-publicIP"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip_prefix" "natgw_pubip_pref" {
  name                = "nat-gateway-publicIPPrefix"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  prefix_length       = 30
}

resource "azurerm_nat_gateway" "NatGW" {
  name                    = "nat-Gateway"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

# Associate public IP and prefix with NAT GW
resource "azurerm_nat_gateway_public_ip_prefix_association" "example" {
  nat_gateway_id      = azurerm_nat_gateway.NatGW.id
  public_ip_prefix_id = azurerm_public_ip_prefix.natgw_pubip_pref.id
}

resource "azurerm_nat_gateway_public_ip_association" "example" {
  nat_gateway_id       = azurerm_nat_gateway.NatGW.id
  public_ip_address_id = azurerm_public_ip.natgw_pubip.id
}

# Associate th NAT Gateway with subnet
resource "azurerm_subnet_nat_gateway_association" "example" {
  subnet_id      = azurerm_subnet.internal.id
  nat_gateway_id = azurerm_nat_gateway.NatGW.id
}

# Create load balancer
resource "azurerm_lb" "main" {
  name                = "${var.prefix}-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "internal"
    # public_ip_address_id = azurerm_public_ip.main.id
    subnet_id                     = azurerm_subnet.internal.id
    #private_ip_address_allocation = "static"
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  name                = "backend-pool"
  #resource_group_name = azurerm_resource_group.main.name
  loadbalancer_id     = azurerm_lb.main.id
}

resource "azurerm_lb_nat_pool" "main" {
  name                           = "nat-pool"
  resource_group_name            = azurerm_resource_group.main.name
  loadbalancer_id                = azurerm_lb.main.id
  frontend_ip_configuration_name = "internal"
  protocol                       = "Tcp"
  frontend_port_start            = 80
  frontend_port_end              = 90
  backend_port                   = 8080
}

resource "azurerm_lb_probe" "main" {
  name                = "lb-probe"
  resource_group_name = azurerm_resource_group.main.name
  loadbalancer_id     = azurerm_lb.main.id
  port                = 22
  protocol            = "Tcp"
}

resource "azurerm_lb_rule" "main" {
  name                           = "lb-rule"
  resource_group_name            = azurerm_resource_group.main.name
  loadbalancer_id                = azurerm_lb.main.id
  probe_id                       = azurerm_lb_probe.main.id
  backend_address_pool_id        = azurerm_lb_backend_address_pool.main.id
  frontend_ip_configuration_name = "internal"
  protocol                       = "Tcp"
  frontend_port                  = 22
  backend_port                   = 22
}

resource "azurerm_linux_virtual_machine_scale_set" "main" {
  name                            = "${var.prefix}-vmss"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  sku                             = "Standard_B1s"
  instances                       = 4
  admin_username                  = "adminuser"
  admin_password                  = "P@ssw0rd1234!"
  disable_password_authentication = false
  health_probe_id                 = azurerm_lb_probe.main.id
  upgrade_mode                    = "Rolling"

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "main"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = azurerm_subnet.internal.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
      load_balancer_inbound_nat_rules_ids    = [azurerm_lb_nat_pool.main.id]
    }
  }

  rolling_upgrade_policy {
    max_batch_instance_percent              = 21
    max_unhealthy_instance_percent          = 22
    max_unhealthy_upgraded_instance_percent = 23
    pause_time_between_batches              = "PT30S"
  }

  identity {
    type = "SystemAssigned"
  }

  extension {
    name                 = "example"
    type                 = "CustomScript"
    type_handler_version = "2.0"
    publisher            = "Microsoft.Azure.Extensions"

    settings = jsonencode({
      "commandToExecute" = "echo $HOSTNAME"
    })
  }

  extension {
    name                 = "AADSSHLogin"
    type                 = "AADSSHLoginForLinux"
    type_handler_version = "1.0"
    publisher            = "Microsoft.Azure.ActiveDirectory"
  }

  depends_on = [azurerm_lb_rule.main]
}

resource "azurerm_monitor_autoscale_setting" "main" {
  name                = "myAutoscaleSetting"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.main.id

  profile {
    name = "Weekends"

    capacity {
      default = 4
      minimum = 2
      maximum = 6
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT2M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 90
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "2"
        cooldown  = "PT1M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT2M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 10
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "2"
        cooldown  = "PT1M"
      }
    }

    # recurrence {
    #   frequency = "Week"
    #   timezone  = "Pacific Standard Time"
    #   days      = ["Saturday", "Sunday"]
    #   hours     = [12]
    #   minutes   = [0]
    # }
  }

  notification {
    email {
      send_to_subscription_administrator    = true
      send_to_subscription_co_administrator = true
      custom_emails                         = ["admin@contoso.com"]
    }
  }
}
