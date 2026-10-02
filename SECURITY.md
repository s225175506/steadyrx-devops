# Security scan findings and decisions

The Security stage runs four scanners on every build. This file records what they found and what was done about each finding. It is updated whenever the pipeline surfaces something new.

| Scanner | Scope | Gate |
| --- | --- | --- |
| Bandit 1.9.4 | Python source (SAST) | Fail on MEDIUM or HIGH severity with MEDIUM or HIGH confidence |
| pip-audit 2.10.1 | Pinned runtime dependencies in `requirements.txt` | Fail on any known vulnerability |
| Trivy 0.69.3 (image) | OS and Python packages inside the runtime image | Fail on HIGH or CRITICAL with a fix available |
| Trivy 0.69.3 (fs) | Committed secrets and Dockerfile misconfiguration | Fail on HIGH or CRITICAL |

Trivy is pinned to 0.69.3 on purpose. Versions 0.69.4 to 0.69.6 of the Trivy images were compromised in the March 2026 supply chain attack (GHSA-69fq-xp46-6x23), and 0.69.3 is listed by Aqua Security as a safe release.

## Findings

### 1. Vendored msgpack 1.1.2 in the runtime image (HIGH, fixed)

* What. GHSA-6v7p-g79w-8964, an out-of-bounds read in MessagePack for Python when an Unpacker is reused after an error. The copy came from the pip package manager inside the base image, not from SteadyRx code.
* Severity. HIGH. Fixed upstream in msgpack 1.2.1.
* Action. The runtime stage of the Dockerfile now uninstalls pip, setuptools and wheel after the dependencies are installed. Production never installs packages at run time, so this removes the vulnerable code and shrinks the attack surface.

### 2. setuptools 70.3.0 in the runtime image (HIGH and MEDIUM, fixed)

* What. CVE-2025-47273, a path traversal in `PackageIndex` that can write files outside the target folder, plus CVE-2026-59890 (MEDIUM).
* Severity. HIGH. Fixed in setuptools 78.1.1 and 83.0.0.
* Action. Removed from the runtime image by the same Dockerfile change. The test image keeps its build tools because it never ships.

### 3. Debian 13 operating system packages (156 findings, accepted with mitigation)

* What. Trivy reports 156 CVEs in the `python:3.12-slim` Debian 13.7 base layer (44 HIGH, 53 MEDIUM, 57 LOW, 2 UNKNOWN). None has a fixed Debian package yet.
* Severity. Mostly LOW and MEDIUM. The HIGH items sit in base system utilities (util-linux, ncurses, the systemd client libraries, perl-base and login). The API never calls these, and nothing in the container exposes a shell.
* Action. The gate uses `--ignore-unfixed`, so the build fails as soon as Debian ships a fix and the image is rebuilt. Until then the risk is reduced because the container runs as a non-root user, with a read-only root filesystem, `no-new-privileges`, CPU and memory limits and no shell exposed. A distroless or Chainguard Python base image is the next step to remove these packages entirely. The full list is archived with every build in `reports/trivy-image.json`.

### 4. SonarCloud reliability finding (fixed)

* What. SonarCloud flagged a test that compared `hash_password("x") != hash_password("x")` as a bug because both sides are the same expression, and a code smell where the app factory shadowed the module-level `app`.
* Action. The test now stores two hashes and also checks that both verify. The factory variable was renamed to `application`.

## Clean results

* Bandit found no issues at any severity in the application code. The alert receiver binds to `0.0.0.0` inside its container, which is expected, and is marked `# nosec B104` with that reason.
* pip-audit found no known vulnerabilities in FastAPI 0.141.1, Uvicorn 0.53.0, Pydantic 2.13.5, PyJWT 2.15.0 or prometheus-client 0.26.0.
* Trivy found no committed secrets. The JWT signing keys are generated per environment by `ci/deploy.ps1` and kept outside the repository.
