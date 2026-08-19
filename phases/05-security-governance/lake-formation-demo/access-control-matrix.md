# IAM and Lake Formation Access-Control Matrix

## Human personas

| Persona | IAM capability added by demo | Database LF permission | Table LF permission | LF-tag permission | Expected data access |
|---|---|---|---|---|---|
| Data engineer | Catalog read + `lakeformation:GetDataAccess` | `DESCRIBE` | `SELECT`, `DESCRIBE`, `ALTER` | None | Read and evolve the isolated demo table |
| Risk analyst | Catalog read + `lakeformation:GetDataAccess` | `DESCRIBE` | `SELECT`, `DESCRIBE` | None | Read-only analytical query access |
| Data steward | Catalog metadata read/update + LF-tag APIs | `DESCRIBE` | `DESCRIBE`, `ALTER` | `DESCRIBE`, `ASSOCIATE` | Govern metadata and classification; no row reads |
| Security auditor | Catalog/Lake Formation read APIs | `DESCRIBE` | `DESCRIBE` | Read-only discovery | Inspect permissions and metadata; no row reads |

## Automated proof roles

| Probe | IAM query path | Lake Formation permission | Required result |
|---|---|---|---|
| Authorized reader | Athena, catalog metadata, encrypted results, `GetDataAccess` | `DESCRIBE` + `SELECT` | `SELECT count(*)` reaches `SUCCEEDED` |
| Metadata-only denied | Identical IAM query path | `DESCRIBE`; deliberately no `SELECT` | The same query reaches `FAILED` |

The negative probe is important: because its IAM query path is present, the denied query demonstrates the Lake Formation decision rather than a missing Athena or S3-results permission.

## Administrative boundary

The bootstrap appends two dedicated roles to the Lake Formation administrator list using `MutationType=APPEND`; existing administrators and account-wide defaults are preserved. `zipco-lake-formation-deployment-dev` is trusted only by CloudFormation and creates the isolated catalog, tags, and grants. `zipco-lf-validation-dev` is trusted only by Lambda and performs hybrid opt-ins, read-back verification, access probes, and evidence publication. This path works even when the initiating CloudShell identity is the account root because root never assumes either role.

Runtime access uses `zipco-lf-data-access-dev`, which Lake Formation assumes only for the registered demo prefix. Human personas do not receive direct object access to `governance-demo/`.

The two query-probe roles trust only the validation role; they are not human sign-in roles.

## Existing-platform boundary

The deployment does not register or opt in any path or resource belonging to:

- `zipco_financial_risk`
- `zipco_financial_analytics`
- `zipco_financial_risk_engine`

Those database table counts are captured before and after deployment as a regression guard. Their current IAM-compatible behavior remains unchanged.
