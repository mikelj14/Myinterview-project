provider "kind" {}

# 1. Define Multi-Node Cluster (1 Control Plane + 2 Workers) with Ingress Port Mappings
resource "kind_cluster" "default" {
  name           = "local-cluster"
  wait_for_ready = true

  kind_config = <<-EOF
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
      - role: control-plane
        kubeadmConfigPatches:
          - |
            kind: InitConfiguration
            nodeRegistration:
              kubeletExtraArgs:
                node-labels: "ingress-ready=true"
        extraPortMappings:
          - containerPort: 80
            hostPort: 80
            protocol: TCP
          - containerPort: 443
            hostPort: 443
            protocol: TCP
      - role: worker
      - role: worker
  EOF
}

# Configure Kubernetes and Helm providers to talk to the newly created Kind cluster
provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  client_certificate     = base64decode(kind_cluster.default.client_certificate)
  client_key             = base64decode(kind_cluster.default.client_key)
  cluster_ca_certificate = base64decode(kind_cluster.default.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.default.endpoint
    client_certificate     = base64decode(kind_cluster.default.client_certificate)
    client_key             = base64decode(kind_cluster.default.client_key)
    cluster_ca_certificate = base64decode(kind_cluster.default.cluster_ca_certificate)
  }
}

# 2. Install NGINX Ingress Controller via Helm
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  set {
    name  = "controller.nodeSelector.ingress-ready"
    value = "true"
  }

  set {
    name  = "controller.tolerations[0].key"
    value = "node-role.kubernetes.io/control-plane"
  }

  set {
    name  = "controller.tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "controller.tolerations[0].effect"
    value = "NoSchedule"
  }
}

# 3. Install Argo CD via Helm
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  # Expose ArgoCD server insecurely for easy local routing/port-forwarding
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [helm_release.ingress_nginx]
}
