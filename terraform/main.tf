provider "kind" {}

# 1. Define Multi-Node Cluster (1 Control Plane + 2 Workers) with Ingress Port Mappings
resource "kind_cluster" "default" {
  name           = "local-cluster"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Label the node so the ingress controller can be pinned to it (it owns the host ports)
      kubeadm_config_patches = [<<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
      EOT
      ]

      # Host ports 80/443 -> control-plane container, so http://localhost reaches the ingress controller
      extra_port_mappings {
        container_port = 80
        host_port      = 80
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
      }
    }

    node {
      role = "worker"
    }

    node {
      role = "worker"
    }
  }
}

# Configure Kubernetes and Helm providers to talk to the newly created Kind cluster
provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  client_certificate     = kind_cluster.default.client_certificate
  client_key             = kind_cluster.default.client_key
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.default.endpoint
    client_certificate     = kind_cluster.default.client_certificate
    client_key             = kind_cluster.default.client_key
    cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
  }
}

# 2. Install NGINX Ingress Controller via Helm
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 600 # first image pulls on a fresh cluster are slow

  # Run on the control-plane node (the one with host ports 80/443 mapped)
  set {
    name  = "controller.nodeSelector.ingress-ready"
    value = "true"
    type  = "string" # label values must be strings; without this helm sends a bool
  }

  # Bind 80/443 directly on the node so kind's extra_port_mappings reach the controller
  set {
    name  = "controller.hostPort.enabled"
    value = "true"
  }

  # No cloud load balancer in kind; LoadBalancer would stay <pending>
  set {
    name  = "controller.service.type"
    value = "NodePort"
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
  timeout          = 600 # first image pulls on a fresh cluster are slow

  # Expose ArgoCD server insecurely for easy local routing/port-forwarding
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [helm_release.ingress_nginx]
}

# 4. metrics-server: CPU/memory metrics for `kubectl top` and the HPA
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  timeout    = 600

  # kind kubelets use self-signed certs; without this metrics-server can't scrape them
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }
}
