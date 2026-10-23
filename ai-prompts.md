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

### Prompt 9
> (pasted) both myapp pods `0/1 CreateContainerConfigError`

Result:
- `kubectl get events` showed: `container has runAsNonRoot and image has non-numeric user (appuser), cannot verify user is non-root`. AI mistake: `runAsNonRoot` in the Deployment + `USER appuser` (name) in the Dockerfile don't work together.
- Dockerfile changed to `USER 10001`; rebuilt image, `kind load`, deleted pods. Now Synced/Healthy, http://localhost serves the page from both pods.

### Prompt 10
> yes start part 3

Result:
- `.github/workflows/ci.yaml`: build + push to GHCR tagged with commit SHA, then `sed` the new tag into `k8s/app.yaml` and commit it (Argo CD deploys; no kubectl in CI).
- Dockerfile: `ARG/ENV APP_VERSION` so the page shows the commit SHA; removed hard-coded `APP_VERSION` from the Deployment.
- Deployment: `preStop: sleep 5` for zero-downtime.
- README: Part 3 section + zero-downtime test loop.

### Prompt 11
> (pasted) `git push` -> `refusing to allow an OAuth App to create or update workflow .github/workflows/ci.yaml without workflow scope`

Result:
- GitHub requires the extra `workflow` scope on a token to push files under `.github/workflows/` (protects against a leaked token planting CI that steals secrets). The `gh` login token didn't have it.
- Fix: `gh auth refresh -h github.com -s workflow`, then `git push` again (commit was already made locally).

### Prompt 12
> make sure we dont push any secrects to the github repo itself

Result:
- Audited tracked files and full git history (private keys, GitHub tokens, AWS keys, passwords, tfstate).
- Found `terraform/local-cluster-config` (kind kubeconfig with admin client key) committed and pushed in `b3816d9`. Untracked it, added `terraform/*-config` and `rollout.log` to `.gitignore`.
- `terraform.tfstate` (also contains keys) confirmed ignored and never committed. Only other hit is `${{ secrets.GITHUB_TOKEN }}`, a reference, not a value.

### Prompt 13
> both  (rotate the leaked key AND rewrite git history)

Result:
- Backup bundle made first, then `git filter-branch --index-filter 'git rm --cached --ignore-unmatch terraform/local-cluster-config' -- --all`; verified no reachable commit contains the file.
- Force-push of the rewritten history was blocked by Claude Code's permission check (destructive git action), so I ran it myself.
- Rotated keys: `terraform destroy && terraform apply`, then re-bootstrapped Argo CD.
