# Developer Onboarding — Running Telco Data Platform

This is the walkthrough a new data engineer would actually follow on day one:
a blank WSL Ubuntu machine, through a fully working local dev environment,
to understanding how code changes actually reach Snowflake and Airflow in a
real company (via CI/CD, not by hand).

Follow the sections in order the first time. After that, only **Section 8
(day-to-day workflow)** matters for routine work.

---

## 1. Windows side — WSL2 + VS Code

If WSL and VS Code aren't installed yet (skip if they are):

```powershell
# In an elevated (Administrator) PowerShell on Windows
wsl --install -d Ubuntu-24.04
```
Reboot if prompted, then open the new Ubuntu terminal once to finish its
first-run setup (create a UNIX username/password — separate from your
Windows login).

Install VS Code from https://code.visualstudio.com/, then inside VS Code
install the **WSL** extension (`ms-vscode-remote.remote-wsl`). From then on,
open your project with `code .` from inside the WSL terminal, or via
`Remote-WSL: New Window` in VS Code's command palette — everything below
runs *inside* WSL, not in Windows.

## 2. Base packages inside WSL

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential curl git unzip jq software-properties-common
```

**Python 3.12** (WSL Ubuntu 24.04 ships it, but confirm):
```bash
python3 --version   # should be 3.12.x
sudo apt install -y python3-pip python3-venv
```

## 3. Git + GitHub

```bash
git config --global user.name "Your Name"
git config --global user.email "you@company.com"

# SSH key for GitHub (skip if you already have one you're reusing)
ssh-keygen -t ed25519 -C "you@company.com"
cat ~/.ssh/id_ed25519.pub
```
Copy that output into GitHub → **Settings → SSH and GPG keys → New SSH key**.
Then test it:
```bash
ssh -T git@github.com   # should greet you by username
```

Clone the repo:
```bash
mkdir -p ~/projects && cd ~/projects
git clone git@github.com:<your-org>/running-telco-snowflake-aws.git
cd running-telco-snowflake-aws
```

## 4. AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
rm -rf awscliv2.zip aws/
```

Configure your **personal** credentials (separate from the CI credentials
set up in Section 6 — those are for GitHub Actions, not your laptop):
```bash
aws configure
# AWS Access Key ID, Secret Access Key, region (e.g. us-east-1), output format (json)
```
Most companies actually use **AWS SSO** instead of static keys for humans —
if your org has that, it looks like `aws configure sso` instead, and you'll
run `aws sso login` at the start of each day rather than storing a
long-lived key. Ask your team which one they use.

## 5. Snowflake tooling

Install SnowSQL (the CLI `deploy.sh` uses):
```bash
curl -O https://sfc-repo.snowflakecomputing.com/snowsql/bootstrap/1.3/linux_x86_64/snowsql-1.3.2-linux_x86_64.bash
bash snowsql-1.3.2-linux_x86_64.bash
source ~/.bashrc
snowsql -v
```

Generate a key pair for **key-pair authentication** (the standard for
service/automation accounts — password auth is fine for your own interactive
use, but don't build automation around it):
```bash
mkdir -p ~/.ssh/snowflake
cd ~/.ssh/snowflake
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```
Give the **public** key's contents (`cat rsa_key.pub`, without the
`-----BEGIN/END-----` lines) to whoever administers your Snowflake account,
to run:
```sql
ALTER USER your_username SET RSA_PUBLIC_KEY='<paste the key body here>';
```

Create `~/.snowsql/config`:
```ini
[connections.dev]
accountname = <your_account_locator>
username = <your_username>
rolename = R_DATA_ENGINEER
warehousename = WH_INGEST
dbname = RUNNING_TELCO
private_key_path = /home/<you>/.ssh/snowflake/rsa_key.p8
```

## 6. VS Code extensions worth installing

- **Python** (`ms-python.python`) — linting, debugging, venv detection
- **Snowflake** (`snowflake.snowflake-vsc`) — run SQL against your connection right from the editor
- **AWS Toolkit** (`amazonwebservices.aws-toolkit-vscode`) — browse S3/IAM without leaving VS Code
- **GitLens** (`eamodio.gitlens`) — see who changed what, when, inline

## 7. Python environment + first local run

```bash
cd ~/projects/running-telco-snowflake-aws/python
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env: fill in SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY_PATH,
# SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE, S3_BUCKET, AWS_REGION
```

Then follow the main **README.md**, Steps 1–5, to deploy the Snowflake
objects (`../deploy.sh <connection_name>`) and run the pipeline
(`generate_telecom_data.py` → `upload_to_s3.py` →
`snowflake_orchestrator.py --layer raw|staging|curated`).

---

## 8. The part most new hires haven't seen before: how DAGs and `requirements.txt` reach Airflow via a bucket

You will **not** SSH into an Airflow server and drop a file in a `dags/`
folder. In almost every company running Airflow at any scale — whether
that's **Amazon MWAA** (Managed Workflows for Apache Airflow) or a
self-hosted Airflow with an S3-sync sidecar — the actual mechanism is:

```
S3 bucket (e.g. s3://acme-mwaa-prod/)
├── dags/
│   ├── running_telco_pipeline_dag.py
│   └── ... every other team's DAGs too
├── requirements.txt          <- Python packages Airflow's workers install
└── plugins.zip                (optional - custom operators/hooks)
```

MWAA (and equivalent self-hosted setups) **polls this bucket** and syncs
any change into the running Airflow environment automatically, usually
within a few minutes — no manual deploy, no server access, no restart.
`requirements.txt` changes trigger MWAA to rebuild its Python environment
in the background.

This is *why* the CI/CD pipeline (Section 9) doesn't "deploy Airflow" the
way you might deploy a web app — it just **syncs files to S3**, and the
managed service takes it from there.

## 9. CI/CD — what actually happens when you open a Pull Request

This repo ships two GitHub Actions workflows:

### `.github/workflows/ci.yml` — runs on every Pull Request
- No credentials required at all.
- Runs `ci/lint_checks.sh` — static checks that encode every structural bug
  hit during this project's own development (multi-role grants, tasks in
  the wrong schema, missing `:`-prefixed bind variables, hardcoded `COPY
  INTO` column positions). If your PR reintroduces one of these, CI fails
  before a human reviewer even looks at it.
- Validates the Airflow DAG file actually parses into the expected 5 tasks.

### `.github/workflows/deploy.yml` — runs on every merge to `main`
- **`deploy-snowflake`** — runs `ci/deploy_snowflake.py`, which applies
  every file in `sql/` to Snowflake in the same order as `deploy.sh`, using
  key-pair auth from GitHub Secrets (never a password, never your personal
  credentials).
- **`sync-airflow-to-s3`** — `aws s3 sync`s `airflow/dags/` and uploads
  `python/requirements.txt` to the MWAA bucket described in Section 8, using
  **AWS OIDC** (no long-lived AWS keys stored in GitHub at all — GitHub
  issues a short-lived token per run that AWS trusts).

### One-time setup an admin needs to do (not you, on day one — but you should understand it)

**Snowflake CI service user** (separate from your personal user):
```sql
CREATE USER SVC_CI_RUNNINGTELCO RSA_PUBLIC_KEY='<CI key pair's public key>';
GRANT ROLE R_TELECOM_ADMIN TO USER SVC_CI_RUNNINGTELCO;
```

**AWS OIDC trust** (lets GitHub Actions assume an AWS role with no stored keys):
```bash
# One-time: register GitHub as an OIDC identity provider in AWS IAM
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```
Then create an IAM role trusting that provider, scoped to this specific
repo (replace `<org>/<repo>`):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:ref:refs/heads/main" }
    }
  }]
}
```
Attach a permission policy scoped only to the MWAA bucket (least privilege —
this role should not be able to touch anything else):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::<mwaa-bucket-name>",
      "arn:aws:s3:::<mwaa-bucket-name>/dags/*",
      "arn:aws:s3:::<mwaa-bucket-name>/requirements.txt"
    ]
  }]
}
```

**GitHub repo secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `SNOWFLAKE_ACCOUNT` | your account locator |
| `SNOWFLAKE_CI_USER` | `SVC_CI_RUNNINGTELCO` |
| `SNOWFLAKE_CI_ROLE` | `R_TELECOM_ADMIN` |
| `SNOWFLAKE_WAREHOUSE` | `WH_INGEST` |
| `SNOWFLAKE_CI_PRIVATE_KEY` | the CI key pair's **private** key PEM contents |
| `AWS_DEPLOY_ROLE_ARN` | the IAM role ARN created above |
| `AWS_REGION` | e.g. `us-east-1` |
| `MWAA_BUCKET_NAME` | the S3 bucket name from Section 8 |

## 10. Day-to-day workflow, once all of the above exists

```bash
git checkout -b feature/add-new-region
# ... make changes to sql/, python/, or airflow/dags/ ...
git add -A && git commit -m "Add EAST region analyst role"
git push -u origin feature/add-new-region
# Open a PR on GitHub -> ci.yml runs automatically -> green check or fix and push again
# Get it reviewed and approved -> merge to main
# -> deploy.yml runs automatically -> Snowflake updated + Airflow DAGs synced
```

You never manually run `deploy.sh` or `aws s3 sync` against shared
dev/staging/prod environments once this is set up — those commands are for
your **own local Snowflake objects** while developing, and CI/CD owns
promoting to shared environments. That separation (local experimentation
vs. CI/CD-owned shared environments) is the actual thing to internalize from
this whole guide.
