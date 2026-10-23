# Myinterview-project – DevOps Technical Exercise

Take a tiny web service from code to a running deployment on a local Kubernetes
cluster, the GitOps way.

AI prompts I sent are logged in [`ai-prompts.md`](ai-prompts.md).

## Plan

| Part | Step | Tool chosen | Status |
|------|------|-------------|--------|
| 0 | Install tooling | brew, Docker (+colima on Mac), kind, kubectl, Terraform, helm, git | done |
| 0 | GitHub repo | `mikelj14/Myinterview-project` | done |
| 0 | Web service: `GET /` HTML (message, version, pod name), `GET /healthz` 200 | Python + Flask, served by gunicorn | done |
| 0 | Dockerfile, non-root user | `python:3.13-slim`, uid 10001 | done |
| 1 | Cluster as code: 1 control-plane + 2 workers, Argo CD, ingress controller | Terraform + `tehcyx/kind` + helm providers, ingress-nginx | done |
| 2 | App manifests in repo, synced by Argo CD | Deployment (2 replicas, probes, requests/limits), Service, Ingress, Argo CD Application | todo |
| 3 | CI: build + push to GHCR tagged with commit SHA, bump tag in git | GitHub Actions | todo |
| 3 | Zero-downtime rollout demo | rolling update + readiness probe + curl loop | todo |
| Bonus | HPA (2–5), Prometheus/Grafana via Argo CD, EKS notes | | todo |

### Why these tools
- **kind** over minikube: multi-node cluster (1 control-plane + 2 workers) in Docker
  with one config file, and a Terraform provider exists for it.
- **ingress-nginx**: kind docs support it directly (node label `ingress-ready=true`
  + host ports 80/443 mapped to the control-plane node).
- **Helm provider in Terraform** to install Argo CD and ingress-nginx, so
  `terraform apply` / `terraform destroy` is the whole lifecycle.

## How to run

```bash
# app locally
docker build -t myapp:dev .
docker run --rm -p 8080:8080 myapp:dev     # http://localhost:8080 and /healthz

# cluster
cd terraform
terraform init
terraform apply      # kind cluster + ingress-nginx + Argo CD
terraform destroy    # removes everything

kubectl get nodes    # 1 control-plane + 2 workers

# Argo CD UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8443:443   # https://localhost:8443, user admin
```

## Progress log

### Part 0 – setup (steps 1–3)
- Learned the Mac shortcuts, opened a terminal, checked git with `git --version`.
- Logged into GitHub, created repo `Myinterview-project`, cloned it, checked the
  remote with `git remote -v`.
- Installed brew as a package manager, then Docker + colima (container runtime on
  Mac), kubectl and Terraform.
- Push to `main` failed at first because the Mac had no access to my GitHub
  account; created a Personal Access Token (PAT) and used it to push.

### Part 0 – web service (steps 4–5)
- Web service in Python. Serves an HTML page on `/` with message, app version and
  pod name (from `HOSTNAME`, which Kubernetes sets to the pod name), and `/healthz`
  returning 200.
- Dockerfile uses `python:3.13-slim`, creates `appuser` (uid 10001) and switches to
  it with `USER`, so the container does not run as root. Port 8080 exposed.
- Mistake: misnamed the requirements file at first, so the `COPY` in the Dockerfile
  failed. Fixed the name.
- Rewrote the app in Flask (the earlier version used only Python's built-in
  `http.server` even though I had asked for Flask, and `requirements.txt` installed
  Flask without the app using it). The page is a Jinja template, which escapes
  values automatically.
- The container runs **gunicorn** instead of Flask's development server. When a pod
  gets SIGTERM, gunicorn finishes the requests it is already handling before it
  exits, which the zero-downtime rollout needs. Two worker processes.
- Tested: `docker run` gives the HTML page, `/healthz` returns `200 OK`, and
  `docker exec ... id` shows `uid=10001(appuser)`, so it is not root.

### Part 1 – cluster as code
- Planned minikube, switched to kind on the AI's suggestion (see "Why these tools").
- `terraform/main.tf` creates the kind cluster, then installs ingress-nginx and
  Argo CD with Helm.
- Cleanup: the `.terraform/` provider binaries (Mac builds, ~100 MB) had been
  committed by mistake. Removed them from git and added `.gitignore`; the
  `.terraform.lock.hcl` stays committed so provider versions are pinned. Renamed
  the folder `Terrform` -> `terraform`.
- First `terraform apply` surfaced 4 problems in the AI-generated Terraform, fixed one by one:
  1. `kind_config` was written as a YAML heredoc string; the `tehcyx/kind` provider
     wants an HCL **block** (`kind_config { node { ... } }`). Error: `An argument named
     "kind_config" is not expected here`.
  2. Provider auth wrapped the certs in `base64decode()`, but the kind provider already
     returns PEM text. Error: `failed to decode base64 data`. Removed `base64decode`.
  3. Helm `set` for `nodeSelector.ingress-ready = "true"` was sent as a bool; Kubernetes
     labels must be strings. Error: `cannot unmarshal bool into ... nodeSelector of type
     string`. Added `type = "string"`.
  4. Not an error but a silent bug I caught reading the config: kind maps host port 80
     to the control-plane container, but nothing listens there unless the ingress
     controller uses `hostPort`. Added `controller.hostPort.enabled=true` and
     `controller.service.type=NodePort` (LoadBalancer would stay `<pending>` in kind).
  5. Helm timed out (default 300s) while pulling images on a fresh cluster; set
     `timeout = 600`.
- Result: 3 nodes `Ready`, ingress-nginx and Argo CD pods `Running`,
  `curl http://localhost/` returns nginx 404, so the ingress is reachable and only
  waiting for routes.

### Part 2 – GitOps deployment
- Image loaded into the kind nodes with `kind load docker-image myapp:dev --name local-cluster`
  (the cluster can't see my local Docker images otherwise). Replaced by GHCR in Part 3.
- `k8s/app.yaml`: Deployment (2 replicas, readiness + liveness probes on `/healthz`,
  CPU/memory requests and limits, `runAsNonRoot`, rolling update with
  `maxUnavailable: 0`), Service (port 80 -> 8080), Ingress (class `nginx`, no host so
  `http://localhost` matches).
- `argocd/application.yaml`: Argo CD Application watching `k8s/` on `main`, with
  automated sync, `prune` (deletes what's removed from git) and `selfHeal` (reverts
  manual kubectl changes). Applied once by hand as bootstrap:
  `kubectl apply -f argocd/application.yaml`. After that, every change goes through git.
- Repo is public, so Argo CD needs no credentials to read it.

## End of build time (fill in at the end)
- **Finished:**
- **Missing:**
- **One decision and why:**
- **Where the AI was wrong and how I noticed:** I asked for a Flask app, but the AI wrote one with only the standard library, and `requirements.txt` still installed Flask, which went unused. I noticed while reviewing the files against my README. Rewrote it in Flask.
  Also the AI-written Terraform had 3 bugs that only showed up on `terraform apply` (see Part 1 log); I noticed from the errors, and a 4th (ingress not reachable on localhost) by reading how kind port mappings work.
