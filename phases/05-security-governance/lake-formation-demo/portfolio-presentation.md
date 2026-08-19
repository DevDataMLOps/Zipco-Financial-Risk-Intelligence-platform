# IAM and Lake Formation — Portfolio Presentation

## Portfolio headline

**Deployed and verified an isolated Lake Formation authorization layer with 18/18 controls passed, observed access and denial, and no disruption to the existing AWS analytics platform.**

## The problem

The ZIPCO platform already had separate IAM personas and a governed Glue catalog, but its existing databases retained IAM-compatible access to avoid breaking working Glue and Athena jobs. Simply claiming “Lake Formation ready” would not prove that fine-grained authorization worked.

## The engineering decision

I created a separate governance sandbox:

- one registered S3 prefix;
- one Glue database and external table;
- two LF-tags for domain and sensitivity;
- four persona-specific LF-TBAC mappings;
- hybrid opt-ins limited to the sandbox;
- two automation-only roles that run the same Athena query with different Lake Formation permissions.

This preserves the existing platform while making the authorization decision observable.

## The control result to show

| Test | IAM query path | Lake Formation `SELECT` | Observed AWS result |
|---|---:|---:|---|
| Authorized reader | Yes | Yes | `SUCCEEDED`, four fixture rows counted |
| Metadata-only reader | Yes | No | `FAILED_AS_EXPECTED`, permission-denial reason retained |

Because both probes have the IAM permissions needed for Athena, Glue metadata, encrypted results, and `lakeformation:GetDataAccess`, the difference in outcome demonstrates Lake Formation enforcement.

## Evidence chain

1. CloudFormation creates the registered location, catalog, LF-tags, persona grants, probe roles, and validator.
2. Lake Formation state is read back through AWS APIs.
3. Six principals are opted in on both the database and table: 12 scoped opt-ins.
4. The positive and negative queries run and their execution IDs and outcomes are retained.
5. Before/after counts confirm all three existing analytics databases are unchanged.
6. An 18-control JSON record is encrypted with the project KMS key and versioned in S3.

## Screenshot sequence

1. Final CloudShell output showing `18/18`, `SUCCEEDED`, `FAILED_AS_EXPECTED`, `12/12`, and `UNCHANGED`.
2. Lake Formation permissions filtered to a ZIPCO persona.
3. Hybrid-access page showing only the demo database/table opt-ins.
4. Registered-location page showing the custom data-access role and hybrid mode.

## Interview explanation

> I did not convert the live catalogs in place because that could interrupt a pipeline I had already verified. I used an isolated hybrid-access catalog to demonstrate LF-tag-based grants and automated both a positive and negative Athena test. The negative role deliberately has the complete IAM query path but no Lake Formation SELECT permission, so the different query outcomes prove the authorization boundary. I also captured before-and-after catalog counts to show the demo did not modify the live analytical model.

## Claim boundary

Before the successful AWS run:

> Implemented an isolated IAM and Lake Formation access-control demonstration with automated validation.

Verified claim supported by the retained final screenshot and authoritative S3 evidence object:

> Deployed and verified Lake Formation tag-based access control with an observed authorized query, an observed denied query, and no changes to the existing analytics databases.
