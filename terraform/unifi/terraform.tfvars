dns_domain = "jort.haus"
site       = "default"

dns_hosts = {
  gaia-01 = "10.1.10.1"
  gaia-02 = "10.1.10.2"
  gaia-03 = "10.1.10.3"
}

frr_enable      = true
frr_description = "Jorthaus BGP configuration"
frr_router_id   = "10.1.0.1"
frr_router_as   = 64512
frr_node_as     = 64512

frr_neighbors = [
  {
    name    = "gaia-01"
    address = "10.1.10.1"
  },
  {
    name    = "gaia-02"
    address = "10.1.10.2"
  },
  {
    name    = "gaia-03"
    address = "10.1.10.3"
  }
]
