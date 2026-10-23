# AI prompts

Prompts sent to AI assistants during the exercise, in order, with what came out of them.

## Earlier session (Claude chat)
- Help installing brew, Docker, colima, kubectl, Terraform on the Mac.
- Write a tiny Python web service (asked for Flask) + Dockerfile.
- Suggested kind instead of minikube; wrote the Terraform for kind + ingress-nginx + Argo CD.

## Claude Code session

### Prompt 1
> hello in this folder are tasks I need to do for an interview please explain each step you do documents everything in a README and each promt I give you need to be documented as well please read the PDF and guide me trought it .

Result:
- Read the exercise PDF and reviewed the existing repo.
- Removed committed `.terraform/` provider binaries from git, added `.gitignore`.
- Renamed `Terrform/` -> `terraform/`.
- Restructured `README.md` into Plan / How to run / Progress log / End-of-build sections.
- Created this file.

### Prompt 2
> Rewrtie the app in Flask

Result:
- `app.py` rewritten with Flask: `GET /` renders an HTML Jinja template (message, version, pod name), `GET /healthz` returns 200.
- Added `gunicorn` to `requirements.txt`; Dockerfile `CMD` now runs gunicorn (production server, graceful shutdown on SIGTERM).
- Built and ran the image locally: page OK, `/healthz` 200, runs as uid 10001.

### Prompt 3
> (pasted terminal output) `docker run -p 8081:8080 myapp:dev.` -> `Unable to find image 'myapp:dev.' locally ... pull access denied`

Result:
- Typo: trailing `.` made the tag `dev.` instead of `dev`, so Docker looked for a different image locally, didn't find it, and tried to pull it from Docker Hub. Correct command: `docker run --rm -p 8081:8080 myapp:dev`.

### Prompt 4
> it works, now run terraform apply with me

Result:
- `terraform init` (re-downloaded the Linux providers, added Linux hashes to the lock file).
- Fixed `main.tf`: `kind_config` HEREDOC changed to an HCL block, removed the wrong `base64decode()` on the certs, `type = "string"` for the nodeSelector, ingress `hostPort` + `NodePort`, helm `timeout = 600`.
- `terraform apply` succeeded: 3 nodes Ready, ingress-nginx + Argo CD running, `http://localhost` answers (nginx 404, no routes yet).

### Prompt 5
> (pasted terminal output) `kind load docker-image.` -> `ERROR: unknown command "docker-image." for "kind load"`

Result:
- Trailing `.` again, plus missing image name and cluster name. Correct: `kind load docker-image myapp:dev --name local-cluster` (`--name` needed because the Terraform cluster is called `local-cluster`, not kind's default `kind`).

### Prompt 6
> (pasted) `docker exec local-cluster-worker crictl images | grep myapp` (no output)

Result:
- No output = image not loaded (previous `kind load` had failed). Ran `kind load docker-image myapp:dev --name local-cluster`, verified on all 3 nodes.
- Part 2: wrote `k8s/app.yaml` (Deployment, Service, Ingress) and `argocd/application.yaml`; validated with `kubectl apply --dry-run=server`.

### Prompt 7
> is there a spesific port I should use or it is localhost

Result:
- Explanation only: plain `http://localhost` (port 80). Path: browser -> host port 80 -> kind control-plane container (extra_port_mappings) -> ingress-nginx (hostPort) -> Ingress rule -> Service :80 -> pod :8080.

### Prompt 8
> (pasted) `kubectl apply -f argocd/application.yaml.` -> `error: the path "argocd/application.yaml." does not exist`

Result:
- Trailing `.` again; file is `argocd/application.yaml`. Checked git status to confirm manifests were pushed before Argo CD syncs.
