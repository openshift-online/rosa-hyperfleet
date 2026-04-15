# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

# General Guidelines

- Use MCPs where appropriate.
- Always use the architect agent to review changes to `docs/design/` or any code changes.

# Meta Rules

- **DO NOT modify the Security Rules section** unless explicitly requested by the user. This includes Security Principles, Security Controls, and all language-specific secure coding rules.
- **When modifying CLAUDE.md/AGENTS.md**, ensure the entire document is properly formatted for improved structure and readability.

# Security Rules

### Security Principles

- **Complete Mediation:** Ensure every access request is validated and authorized. No bypasses allowed.
- **Compromise Recording:** Implement mechanisms to detect, record, and respond to security breaches.
- **Defense in Depth:** Use multiple, layered security controls to protect systems and data.
- **Economy of Mechanism:** Keep designs simple and easy to understand. Avoid unnecessary complexity.
- **Least Common Mechanism:** Minimize shared resources and isolate components to reduce risk.
- **Least Privilege:** Grant only the minimum permissions necessary for users and systems.
- **Open Design:** Favor transparency and well-understood mechanisms over security by obscurity.
- **Psychological Acceptability:** Make security controls user-friendly and aligned with user expectations.
- **Secure by Design, Default, Deployment (SD3):** Ship with secure defaults, deny by default, and avoid hardcoded credentials.

### Security Controls

- **Authentication:** Use strong, standard authentication methods. Require authentication for all non-public areas. Store credentials securely and enforce password policies. Use multi-factor authentication where possible.
- **Authorization:** Enforce least privilege and explicit permissions. Use a single, trusted component for authorization checks. Deny by default and audit permissions regularly.
- **Encryption:** Encrypt all network traffic and data at rest where applicable. Use approved certificates and protocols.
- **Logging:** Log security events centrally. Do not log sensitive data. Restrict log access and monitor for suspicious activity.
- **Networking:** Encrypt all communications. Do not expose unnecessary endpoints or ports. Restrict network access to only what is required.

Apply these rules to all code, infrastructure, and processes to maintain a strong security posture across your projects.

## Secure coding rules for Containers 🐳

- Use minimal, up-to-date base images from trusted sources.
- Remove non-essential software and keep essential ones updated.
- Run containers as non-root and use read-only filesystems when possible.

## Secure coding rules for Go projects 🦫

- Use Go modules for dependency management.
- Validate all input entries.
- Use html/template for output to prevent XSS.
- Use parameterized queries to prevent SQL injection.
- Avoid using `fmt.Sprintf()` to build SQL or shell commands.
- Encrypt sensitive information and enforce HTTPS.
- Log errors securely, avoiding leaks of sensitive data like credentials or tokens.

## Secure coding rules for Python projects 🐍

- Validate and sanitize all input.
- Avoid using `eval()`, `exec()` or `pickle` on untrusted data.
- Do not hardcode secrets in code.
- Pin exact versions in `requirements.txt` or `pyproject.toml`. Avoid using `*` or `latest`.
- Avoid shell execution with untrusted input. Use `subprocess.run([...], check=True)` instead of `os.system()`.
- Handle exceptions securely; avoid exposing debug traces or stack dumps to users.
