---
name: dynamic-k8s-credentials
description: >
  Safely provision, rotate, and validate dynamically issued credentials consumed
  by Jorthaus Kubernetes workloads. Use for OpenBao PostgreSQL credentials, CSI
  Secret sync, short-lived API credentials, and credential-triggered rollouts.
---

# Dynamic Kubernetes Credentials

## Goal

Keep dynamically issued credentials internally consistent and ensure workloads
adopt them without exposing secret values.

## Rules

1. **Treat a dynamic credential endpoint as an issuance operation**
   - A read can create a distinct lease, username, password, or token.
   - Fetch coupled fields, such as a database username and password, from the
     same issuance response.
   - Do not configure separate reads of a dynamic endpoint for each coupled
     field unless the provider explicitly guarantees that they share one cached
     response.

2. **Materialize coupled fields atomically**
   - When a CSI provider cannot map multiple fields from one dynamic read,
     use a purpose-built sync workload or agent that reads once and writes the
     resulting Kubernetes Secret atomically.
   - Preserve the Secret name and key contract expected by the application.

3. **Validate without printing values**
   - Report key names, lease metadata, and boolean checks only.
   - Test a newly materialized credential pair from the workload network path
     using the real transport settings, such as database TLS verification.
   - Confirm the application can authenticate before treating a Secret update
     as successful.

4. **Plan consumer adoption**
   - Environment-variable consumers do not reload when a Kubernetes Secret
     changes.
   - Use a controlled rollout or an application-native reload after validating
     the new credential. Do not rely on unrelated node reboots as the sole
     rotation mechanism.
   - Account for rollout duration, credential overlap, and lease expiry before
     revoking an old credential.

5. **Verify the complete lifecycle**
   - Confirm the issuer policy, Kubernetes auth binding, Secret sync, consumer
     rollout, and application logs after one full refresh.
   - Treat repeated authentication errors as a credential-lifecycle incident;
     stop adding dependent configuration until the credential path is healthy.
