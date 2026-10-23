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
| 2 | App manifests in repo, synced by Argo CD | Deployment (2 replicas, probes, requests/limits), Service, Ingress, Argo CD Application | done |
| 3 | CI: build + push to GHCR tagged with commit SHA, bump tag in git | GitHub Actions | done |
| 3 | Zero-downtime rollout demo | rolling update + readiness probe + curl loop | done |
| Bonus | HPA (2–5), Prometheus/Grafana via Argo CD, EKS notes | metrics-server + HPA, kube-prometheus-stack | HPA + monitoring done, EKS notes todo |

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
pip install -r requirements.txt pytest && pytest -q   # unit tests (same as CI)
docker build -t myapp:dev .
docker run --rm -p 8080:8080 myapp:dev     # http://localhost:8080 and /healthz

# cluster
cd terraform
terraform init
terraform apply      # kind cluster + ingress-nginx + Argo CD
terraform destroy    # removes everything

kubectl get nodes    # 1 control-plane + 2 workers

# bootstrap Argo CD apps (once per cluster; after this everything goes through git)
kubectl apply -f argocd/application.yaml          # the app  -> http://localhost
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18)"
kubectl apply -f argocd/monitoring.yaml           # Prometheus + Grafana

# Argo CD UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8443:443   # https://localhost:8443, user admin
```

## Study guide (summary of everything)

### The whole flow in one picture
```
git push (code)                                   browser: http://localhost
   |                                                     |
GitHub Actions: pytest -> docker build -> Trivy      host port 80
   -> push ghcr.io/...:<sha>                             | (kind extra_port_mappings)
   -> bot commit: image tag in k8s/app.yaml        control-plane node
   |                                                     | (hostPort)
Argo CD (polls git ~3 min) sees new commit         ingress-nginx -> Ingress rule
   -> applies k8s/ to the cluster                        |
   -> Deployment rolling update                    Service myapp :80
      (new pod Ready before old one stops)               |
                                                   pods :8080 (gunicorn + Flask), 2-5 via HPA
```
Terraform builds the platform (kind cluster, ingress-nginx, Argo CD, metrics-server).
Argo CD deploys everything on top (app, Prometheus/Grafana). CI never touches the cluster.

### Steps in order
1. Tools + GitHub repo (Mac: brew, Docker + colima, kubectl, Terraform; later Arch Linux).
2. Flask app (`/` page, `/healthz`), gunicorn, Dockerfile as non-root uid 10001. Tested with `docker run`.
3. Terraform: kind 1+2 nodes, ingress-nginx, Argo CD. `terraform apply` / `destroy`.
4. Manifests in `k8s/` (Deployment, Service, Ingress) + Argo CD Application. App on http://localhost.
5. CI: build, push to GHCR by commit SHA, bump the tag in git. Argo CD deploys it.
6. Zero-downtime: maxUnavailable 0, readiness probe, preStop sleep, gunicorn graceful stop. Curl loop: 0 failures.
7. Bonus: metrics-server + HPA (2-5), load test scaled to 5.
8. Bonus: Prometheus + Grafana as an Argo CD Application from the Helm chart.
9. Production review: CI test + Trivy gate, smaller image (pip/setuptools removed).

### Every error we hit
| # | Where | Error / symptom | Cause | Fix | How found |
|---|-------|-----------------|-------|-----|-----------|
| 1 | App | `requirements.txt` had Flask, app didn't use it | AI wrote stdlib `http.server` though I asked for Flask | Rewrote in Flask + gunicorn | Reading files vs README |
| 2 | Git | ~100 MB pushed, "Large files" warning | Mac `.terraform/` provider binaries committed | Untracked, `.gitignore` | `git ls-files` |
| 3 | Docker | `Unable to find image 'myapp:dev.'` | Trailing `.` in the command (also `docker-image.`, `application.yaml.`) | Remove the dot | Error message names the wrong value |
| 4 | Terraform | `An argument named "kind_config" is not expected here` | Provider wants an HCL block, not a YAML heredoc | `kind_config { node { ... } }` | `terraform apply` |
| 5 | Terraform | `failed to decode base64 data` | Certs already PEM, wrapped in `base64decode()` | Removed it | `terraform apply` |
| 6 | Terraform | `cannot unmarshal bool into ... nodeSelector of type string` | Helm `set` turned `"true"` into a bool | `type = "string"` | `terraform apply` |
| 7 | Terraform | (silent) localhost never reaches the ingress | Port 80 mapped to the node, but nothing listened there | `controller.hostPort.enabled=true` | Reading the kind ingress docs |
| 8 | Terraform | Helm `context deadline exceeded` | Image pulls on a fresh cluster > 300 s | `timeout = 600` | `terraform apply` |
| 9 | Kubernetes | `CreateContainerConfigError`: `image has non-numeric user (appuser), cannot verify user is non-root` | `runAsNonRoot` can only check a numeric UID | `USER 10001` in Dockerfile | `kubectl get events` |
| 10 | Git | `refusing to allow an OAuth App to create or update workflow ... without workflow scope` | Token lacked `workflow` scope (needed for `.github/workflows/`) | `gh auth refresh -h github.com -s workflow` | Push error |
| 11 | Security | Admin kubeconfig (client key) committed + pushed | kind provider writes `terraform/local-cluster-config`; `git add -A` took it | Gitignore, rotate keys (`destroy` + `apply`), rewrite history (`filter-branch`), force-push | Secret audit of history |
| 12 | Git | `cannot parse expected object name '05af72f'` | After `gc`, the short SHA no longer resolved locally | Full SHA from `git ls-remote` in `--force-with-lease` | Push error |
| 13 | Git | `unable to execute pager 'less'` | `less` not installed on Arch | `git --no-pager ...` / `pacman -S less` | Error |
| 14 | Git | `cannot pull with rebase: You have unstaged changes` | Pulled before committing | Commit, then `pull --rebase`, then push | Error |
| 15 | Git | `fatal: not a git repository` | Ran from the parent folder | `cd Myinterview-project` | Error |
| 16 | Zero-downtime | Loop showed 0 failures but tested nothing | Argo CD deployed after the loop stopped (~3 min polling) | Check ReplicaSet `CREATED` is inside the loop window; force refresh | Comparing timestamps |
| 17 | HPA | (design) HPA and Argo CD would fight over replicas | `replicas: 2` in git + selfHeal | Removed `replicas`, HPA owns it | Reasoning before deploy |
| 18 | Monitoring | Grafana forever `OutOfSync`, restarting | Chart makes a random password each render | `admin.existingSecret` (secret made by hand) | Argo CD resource status + RS diff |
| 19 | Monitoring | Prometheus `PodInitializing` 7+ min | Slow image pull | Waited | `kubectl describe pod` events |
| 20 | Security | 4 HIGH CVEs in the image | `pip`/`setuptools` left in the runtime image | Uninstall them after install | Trivy scan |

### Concepts to be able to explain
- **GitOps**: git is the source of truth; Argo CD pulls and applies, CI only commits.
  No cluster credentials in CI.
- **Readiness vs liveness**: readiness = gets traffic or not; liveness = restart or not.
- **Zero-downtime recipe**: `maxUnavailable: 0` + readiness probe + `preStop` sleep +
  app that drains on SIGTERM.
- **Requests vs limits**: request = reserved for scheduling (and the HPA's 100%);
  limit = hard cap (memory over = OOMKilled, CPU over = throttled).
- **Why tag by commit SHA**: every image traceable to code, rollback = revert the commit.
- **Secret hygiene**: check `git status` before `git add -A`; a leaked key must be
  rotated, deleting it from history alone isn't enough (forks/clones/caches keep it).

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

- Secret leak found in a review: the kind provider writes the cluster's kubeconfig to
  `terraform/local-cluster-config` (contains the admin client key), and it got
  committed with `git add -A`. Untracked it and added `terraform/*-config` to
  `.gitignore`. Risk was low (API server only listens on 127.0.0.1 of my laptop),
  but the key stays valid until the cluster is recreated (`terraform destroy && terraform apply`
  generates a new CA and keys). `terraform.tfstate` also holds the keys; it was
  gitignored from the start and never committed. Lesson: check `git status` before
  `git add -A`.
  - Rotated: `terraform destroy && terraform apply` (new cluster = new CA + keys, old
    key useless). This also proved `destroy` removes everything.
  - Removed from history: `git filter-branch --index-filter 'git rm --cached
    --ignore-unmatch terraform/local-cluster-config' -- --all`, deleted the
    `refs/original` backup, `git gc --prune=now`, then `git push --force-with-lease`.
    Commit SHAs from that point on changed.

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
- Bug (from the AI): pods stuck in `CreateContainerConfigError`:
  `container has runAsNonRoot and image has non-numeric user (appuser), cannot verify
  user is non-root`. Kubernetes can only check a numeric UID. Fixed the Dockerfile to
  `USER 10001` (same user, by number), rebuilt, `kind load`, deleted the old pods.
  Found with `kubectl get events`.
- Result: Argo CD app `Synced` / `Healthy`, 2 pods Running, `http://localhost` returns
  the page and refreshing shows both pod names (Service load-balances).

### Part 3 – CI/CD
- `.github/workflows/ci.yaml`, on push to `main`:
  1. builds the image and pushes `ghcr.io/mikelj14/myinterview-project:<commit sha>`
     (login with the built-in `GITHUB_TOKEN`, `permissions: packages: write`);
  2. `sed` replaces the `image:` line in `k8s/app.yaml` with the new tag and commits it
     as `github-actions[bot]`. Argo CD sees the commit and rolls out. No kubectl in CI.
  - Commits pushed with `GITHUB_TOKEN` don't trigger new workflow runs, so the bump
    commit can't cause an endless loop.
- The commit SHA is passed as build-arg `APP_VERSION`, so the page shows which build
  is serving (removed the hard-coded `APP_VERSION` env from the Deployment, it
  would override it).
- GHCR package set to **public** (GitHub > Packages > myinterview-project > Package
  settings > Change visibility), so the cluster pulls without an imagePullSecret.
- Zero-downtime pieces:
  - `maxUnavailable: 0`, `maxSurge: 1`: a new pod must be Ready before an old one stops.
  - readiness probe: a new pod gets traffic only when `/healthz` answers.
  - `preStop: sleep 5`: endpoint removal and SIGTERM happen at the same time; the
    sleep gives ingress-nginx time to stop routing to the old pod first.
  - gunicorn finishes in-flight requests on SIGTERM.
- Verified end to end on the rebuilt cluster: push -> CI built
  `ghcr.io/mikelj14/myinterview-project:0698322...` -> bot commit bumped the tag ->
  Argo CD `Synced`/`Healthy` -> page at http://localhost shows version `0698322...`.
- **Quality gate added later** (production review): CI now runs, in order,
  `pytest` (`test_app.py`: `/` shows message/version/pod, `/healthz` returns `ok`) ->
  build into the runner's Docker only (`load: true`) -> **Trivy** scan, fail on
  HIGH/CRITICAL CVEs that have a fix -> `docker push` -> tag bump. Any failure stops
  the job, so nothing broken or vulnerable reaches GHCR or the cluster.
  - First local scan of the running image: 0 CRITICAL, 4 HIGH, all in `pip`'s bundled
    `msgpack`/`urllib3` and in `setuptools`: install tools, not used at runtime.
    Fix: `pip uninstall -y pip setuptools` after installing requirements. Rescan: 0 findings.
  - `trivy-action` pinned to a commit SHA, not a tag (a tag can be moved to point at
    malicious code; a SHA can't).
- Test: start the loop, change `MESSAGE` in `k8s/app.yaml`, commit, push, watch:
  ```bash
  while true; do curl -s -o /dev/null -w "$(date +%T) %{http_code}\n" http://localhost/; sleep 0.2; done | tee rollout.log
  # after the rollout, Ctrl+C, then count non-200 responses (want 0):
  grep -vc ' 200$' rollout.log
  ```
- **Result: 0 failed requests.** Loop ran 10:30:42-10:31:16 UTC (146 requests, every
  one `200`); both new pods started inside that window (10:30:48 and 10:30:58).
  Rollout triggered with `kubectl rollout restart deploy/myapp`: same RollingUpdate
  path as a git deploy, just without waiting for CI + Argo CD.
  The git-driven rollouts (MESSAGE changes, commits `90e31ba`, `c469e65`) also
  completed fine, page now shows "zero-downtime test 2".
- Gotcha: my first two loop runs also showed 0 failures, but they proved nothing:
  the new ReplicaSet was created *after* Ctrl+C. Argo CD polls git only every
  ~3 min. Fix: always check that the ReplicaSet `CREATED` time falls inside the loop's
  time range, and force an immediate sync with
  `kubectl -n argocd annotate application myapp argocd.argoproj.io/refresh=normal --overwrite`.

## Bonus

### HPA (2-5 pods)
- HPA needs live CPU numbers, and kind doesn't ship them. Added `helm_release.metrics_server`
  to `terraform/main.tf` with `--kubelet-insecure-tls` (kind kubelets use self-signed
  certs). `terraform apply`: 1 added, 0 changed. `kubectl top pods` works.
- `HorizontalPodAutoscaler` in `k8s/app.yaml`: min 2, max 5, target 70% CPU.
  The % is measured against the pod's CPU **request** (50m), not the limit.
- Removed `replicas: 2` from the Deployment. Otherwise there are two owners of the
  replica count: the HPA scales up, Argo CD selfHeal sees drift from git and sets it back to 2.
  The HPA's `minReplicas: 2` now guarantees the 2 pods.
- Load test: in-cluster busybox pod, 4 parallel `wget` loops against `http://myapp`:
  ```bash
  kubectl run load --image=busybox:1.36 --restart=Never -- /bin/sh -c 'for i in 1 2 3 4; do (while true; do wget -q -O- http://myapp >/dev/null; done) & done; wait'
  kubectl get hpa myapp -w
  kubectl delete pod load   # stop; scale-down follows after the 5 min stabilization window
  ```
  Result: CPU went `2%` -> `303%` -> `452%` of target; replicas 2 -> 4 -> 5 within ~30 s,
  then stayed at the max of 5 (~410% even with 5 pods, so the cap is what holds it).

### Prometheus + Grafana via Argo CD
- `argocd/monitoring.yaml`: an Argo CD Application whose source is the
  `kube-prometheus-stack` Helm chart (pinned `92.11.0`), not this repo. Values inline
  (`valuesObject`). Bootstrapped once, like the app:
  ```bash
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18)"
  kubectl apply -f argocd/monitoring.yaml
  ```
  (`kubectl create namespace monitoring` first on a fresh cluster.)
- Turned off: scraping etcd / controller-manager / scheduler / kube-proxy (kind binds them
  to 127.0.0.1, so they'd only show "target down") and Alertmanager (nowhere to send alerts).
- `ServerSideApply=true`: the operator's CRDs are too big for client-side apply's
  annotation (256KB limit).
- Problem hit: with no admin password set, the Grafana chart generates a random one on
  **every render**. Argo CD then sees the Secret (and the Deployment's checksum annotation)
  differ from the cluster on every check: forever `OutOfSync`, and selfHeal kept
  restarting Grafana, which then failed its liveness probe mid-startup. Fix: password in a
  secret created by hand (`grafana.admin.existingSecret`), so it's stable and not in git.
- Open Grafana:
  ```bash
  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
  # http://localhost:3000, user admin. Dashboards > Kubernetes / Compute Resources / Namespace (Pods), namespace default
  ```

## End of build time (fill in at the end)
- **Finished:**
- **Missing:**
- **One decision and why:**
- **Where the AI was wrong and how I noticed:** I asked for a Flask app, but the AI wrote one with only the standard library, and `requirements.txt` still installed Flask, which went unused. I noticed while reviewing the files against my README. Rewrote it in Flask.
  Also the AI-written Terraform had 3 bugs that only showed up on `terraform apply` (see Part 1 log); I noticed from the errors, and a 4th (ingress not reachable on localhost) by reading how kind port mappings work.
