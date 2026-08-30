resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend              = vault_auth_backend.kubernetes.path
  kubernetes_host      = "https://k8s.service.jort.haus:6443"
  kubernetes_ca_cert   = file("${path.module}/kubernetes-ca.pem")
  disable_local_ca_jwt = true
  issuer               = "https://kubernetes.default.svc.cluster.local"
}
