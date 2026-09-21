# AI Usage Disclosure

AI assistance was used during the assessment as a supporting tool. The implementation decisions, requirements, and verification were reviewed and validated manually.

## 1. Documentation

* **Tool/model:** ChatGPT (GPT-5.6 Luna)
* **Purpose:** Helped structure and improve the Markdown documentation.
* **Files or decisions affected:** `README.md`, `decisions.md`, `security_review.md`, `troubleshooting.md`, `log_analysis.md`.
* **What you changed or rejected:** I provided the required sections, technical decisions, evidence, and project details; AI helped organize and phrase them.
* **How you independently verified it:** Documentation was reviewed against the actual project configuration, scripts, commands, and test results.
* **Related commit:** Documentation commits in the repository(docs: ).

## 2. Validation and Utility Scripts

* **Tool/model:** ChatGPT (GPT-5.6 Luna)
* **Purpose:** Assisted with the structure and implementation of validation, failure-testing, backup, and restore scripts.
* **Files or decisions affected:** `validate.py`, `failure_test.py`, `backup.sh`, `restore.sh`.
* **What you changed or rejected:** I provided the required checks, expected behavior, failure scenarios, and recovery logic; AI assisted with implementation details.
* **How you independently verified it:** Scripts were executed locally and their results were checked against the expected application, network, persistence, backup, restore, and failure behavior.
* **Related commit:** 28054da feat: add logical backup and restore,
ae4f3e4 feat: add failure_test script,
a6611e5 feat: add network checks in validate.py,
7e53aaf feat: add validation script

## 3. CI Workflow

* **Tool/model:** ChatGPT (GPT-5.6 Luna)
* **Purpose:** Assisted with structuring the GitHub Actions CI workflow.
* **Files or decisions affected:** `.github/workflows/ci.yml`.
* **What you changed or rejected:** I specified the required CI sequence and validation behavior; AI helped translate it into the workflow configuration.
* **How you independently verified it:** The workflow was pushed to GitHub and the CI run completed successfully for the final implementation.
* **Related commit:** d46f6f4 ci: add GitHub Actions validation workflow
